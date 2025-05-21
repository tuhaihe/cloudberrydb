const Configuration = {
  extends: ["@commitlint/config-conventional"],
  parserPreset: "conventional-changelog-atom",
  formatter: "@commitlint/format",
  rules: {
    "header-case": [2, "always", ["sentence-case", "start-case"]],
    "header-trim": [1, "always"],
    "header-max-length": [1, "always", 72], //Default is 50
    "header-full-stop": [1, "never", "."], // End with .
    "body-leading-blank": [2, "always"],
    "body-empty": [ "never" ], // Empty body is not allowed
    "body-max-line-length": [1, "always", 72], //Max line length
    "footer-leading-blank": [1, "always"], // footer settings
    "footer-pattern": [
      2,
      "always",
      // Eg,:
      // Reported-by: John <john@example.com>
      // See: Issue#123 <https://github.com/...>
      new RegExp(
        "^(Reported-by|Co-authored-by|on-behalf-of|See|https|http):\\s" +
        ".+"
      )
    ]
  },
  helpUrl: "https://github.com/apache/cloudberry/blob/main/.gitmessage",
};

export default Configuration;
