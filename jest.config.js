/** @type {import('jest').Config} */
module.exports = {
  testEnvironment: "jest-environment-jsdom",
  testMatch: ["**/__tests__/**/*.test.js"],
  transform: {},
  setupFilesAfterEnv: ["<rootDir>/__tests__/chrome-extension/setup.js"],
};
