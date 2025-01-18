# Development Environment Setup

This repository provides an automated script to configure your development environment with your preferred editor and terminal tool.

## Installation

1. Clone this repository:
   ```bash
   git clone https://github.com/nabigod/dev-env.git
   ```

2. Navigate to the cloned directory:
   ```bash
   cd dev-env
   ```

3. Run the `setup_devenv.sh` script to configure your environment.

## Usage

### Options

- `-e, --editor`: Choose the editor (`neovim` or `vim`).
- `-t, --terminal`: Choose the terminal tool (`tmux` or `screen`).
- `-f, --force`: Force overwrite existing files with symlinks.
- `-v, --verbose`: Enable verbose output.
- `-h, --help`: Show help message.

### Examples

1. Set up Neovim and Tmux:
   ```bash
   ./setup_devenv.sh -e neovim -t tmux
   ```

2. Force overwrite and enable verbose:
   ```bash
   ./setup_devenv.sh -e vim -t tmux -f -v
   ```

## File Structure

```
.
├── README.md          # This file
├── editor             # Editor configurations (neovim, vim)
├── setup_devenv.sh    # Setup script
└── terminal           # Terminal configurations (tmux)
```
