# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] - TBD
### Added
- Methods to convert a DictLogger to a PSJobLogger class and back again
- Support for `ParentId` with `Write-Progress` calls

### Changed
- Use a single method to format a message to be logged

### Removed

## [0.3.0] - 2023-07-15
### Added
- Messages can be logged to a file in addition to the regular output streams
- A non-class version of the logger that can be used in existing PowerShell (<7.4) jobs

### Changed
- Use .Net `ConcurrentQueue` and `ConcurrentDictionary` for thread-safe collections
- Adding messages to an output stream queue is optional; controlled by an initialization parameter
- Ensure progress records in a completed state are removed after calling Write-Progress

### Removed

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
