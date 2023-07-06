# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2023-07-06
### Added

### Changed
- Progress stream messages are processed in a separate function
- Errors from calling `Write-*` are caught and written to the Error stream
- Remove keys from the Progress stream hashtable after calling `Write-Progress` with `Completed = $true`

### Removed

## [0.1.0] - 2023-07-04
### Added
- Initial commit

### Changed

### Removed
