# Contributing

Thank you for your interest in contributing to DemoFlow!

## Getting Started

1. Fork the repository
2. Clone your fork: `git clone <your-fork-url>`
3. Open `DemoFlow.xcodeproj` in Xcode 16+
4. Build and run (`⌘R`)

## Development

- Build from command line:
  ```bash
  xcodebuild -project DemoFlow.xcodeproj -scheme DemoFlow -destination 'platform=macOS' build
  ```
- The default build configuration is **AppStore** (without yt-dlp)
- For full functionality locally, switch to **Release**

## Pull Requests

- Keep PRs focused — one feature or fix per PR
- Follow existing code style and conventions
- If you're fixing a bug, describe the problem and how your change addresses it
- For new features, briefly explain the motivation

## Reporting Issues

When filing a bug, please include:

- macOS version
- DemoFlow version
- Steps to reproduce
- Expected vs. actual behavior

## Code of Conduct

- Be respectful and constructive
- No harassment or discrimination
- Keep discussions focused on the project

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
