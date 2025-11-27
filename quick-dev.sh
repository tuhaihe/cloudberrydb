#!/bin/bash
# Quick Cloudberry Development Environment Setup
# This script builds Cloudberry and creates a demo cluster in a Docker container
# All in ONE Docker command!
#
# Usage:
#   ./quick-dev.sh                                    # Use default rocky9-latest
#   ./quick-dev.sh rocky8-latest                      # Use rocky8-latest
#   ./quick-dev.sh ubuntu22.04-latest                 # Use ubuntu22.04-latest
#   ./quick-dev.sh apache/incubator-cloudberry:custom # Use custom image

set -e

# Default values
DEFAULT_IMAGE="apache/incubator-cloudberry:cbdb-build-rocky9-latest"
HOST_PORT=5432
FORCE_REMOVE=false

# Function to display usage
usage() {
    echo "Usage: $0 [-p <port>] [-f] [image_tag]"
    echo "  -p  Host port to map to 5432 (default: 5432)"
    echo "  -f  Force remove existing container with the same name"
    echo "  image_tag  Docker image tag or full name (default: rocky9-latest)"
    exit 1
}

# Parse command-line options
while getopts "p:fh" opt; do
    case "${opt}" in
        p)
            HOST_PORT=${OPTARG}
            ;;
        f)
            FORCE_REMOVE=true
            ;;
        h)
            usage
            ;;
        *)
            usage
            ;;
    esac
done
shift $((OPTIND-1))

# Get image from argument or use default
IMAGE="${1:-$DEFAULT_IMAGE}"

# If argument doesn't contain '/', assume it's just the tag part
if [[ ! "$IMAGE" =~ / ]]; then
    IMAGE="apache/incubator-cloudberry:cbdb-build-${IMAGE}"
fi

# Extract a clean name for the container from the image tag
if [[ "$IMAGE" =~ :cbdb-build-(.+)-latest$ ]]; then
    OS_VERSION="${BASH_REMATCH[1]}"
    CONTAINER_NAME="cbdb-${OS_VERSION}"
elif [[ "$IMAGE" =~ :(.+)$ ]]; then
    TAG="${BASH_REMATCH[1]}"
    CONTAINER_NAME="cbdb-${TAG}"
else
    CONTAINER_NAME="cbdb-dev"
fi

# Append port to container name if it's not the default, to allow multiple instances
if [[ "$HOST_PORT" != "5432" ]]; then
    CONTAINER_NAME="${CONTAINER_NAME}-${HOST_PORT}"
fi

echo "📦 Image: $IMAGE"
echo "🏷️  Container name: $CONTAINER_NAME"
echo "🔌 Port mapping: $HOST_PORT:5432"
echo ""

# Check if container already exists
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "⚠️  Container '${CONTAINER_NAME}' already exists."
    
    if [ "$FORCE_REMOVE" = true ]; then
        echo "🗑️  Force removing existing container..."
        docker rm -f ${CONTAINER_NAME}
    else
        read -p "Do you want to remove it and create a new one? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "🗑️  Removing existing container..."
            docker rm -f ${CONTAINER_NAME}
        else
            echo "❌ Aborted. Please remove the container manually or use a different name/port."
            exit 1
        fi
    fi
fi

# Pre-create build-logs directory with correct permissions
# This prevents "Permission denied" errors when the container tries to write logs
if [ ! -d "build-logs" ]; then
    echo "📁 Creating build-logs directory..."
    mkdir -p build-logs
    chmod 777 build-logs
fi

echo "🚀 Starting Cloudberry development container..."
echo "📦 This will build Cloudberry and create a demo cluster in ONE command!"
echo ""

docker run -it \
  --name ${CONTAINER_NAME} \
  -h cdw \
  -p ${HOST_PORT}:5432 \
  -v /sys/fs/cgroup:/sys/fs/cgroup:ro \
  -v $(pwd):/home/gpadmin/cloudberry \
  ${IMAGE} \
  bash -c '
    set -e

    echo "🔐 Initializing SSH..."
    # Manually execute key steps from /tmp/init_system.sh (without the final /bin/bash)
    # We do this manually because /tmp/init_system.sh ends with /bin/bash, which would block the script.
    sudo /usr/sbin/sshd
    sudo rm -rf /run/nologin
    mkdir -p ~/.ssh && chmod 700 ~/.ssh
    ssh-keygen -t rsa -b 4096 -C gpadmin -f ~/.ssh/id_rsa -P "" -q
    cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
    ssh-keyscan -t rsa cdw >> ~/.ssh/known_hosts 2>/dev/null

    echo "📁 Using mounted source directory /home/gpadmin/cloudberry"
    export SRC_DIR=/home/gpadmin/cloudberry
    cd "$SRC_DIR"

    echo "🔧 Configuring Cloudberry (creating build-logs)..."
    mkdir -p build-logs
    ./devops/build/automation/cloudberry/scripts/configure-cloudberry.sh

    echo "🏗️  Building Cloudberry (this may take several minutes)..."
    ./devops/build/automation/cloudberry/scripts/build-cloudberry.sh

    echo "🗄️  Creating demo cluster..."
    ./devops/build/automation/cloudberry/scripts/create-cloudberry-demo-cluster.sh

    echo "⚙️  Loading environment..."
    source /usr/local/cloudberry-db/cloudberry-env.sh
    source $SRC_DIR/gpAux/gpdemo/gpdemo-env.sh

    cat <<EOF

==========================================================
🎉 Cloudberry Development Environment is Ready!
==========================================================
Database is running and ready to accept connections.

Quick Commands:
  psql postgres          - Connect to database
  gpstate                - Check cluster status
  gpstop -a              - Stop database
  gpstart -a             - Start database

Container Management:
  Exit:    exit (or Ctrl+D)
  Re-enter: docker exec -it ${CONTAINER_NAME} bash
  Remove:   docker rm -f ${CONTAINER_NAME}
==========================================================

EOF

    exec bash
  '
