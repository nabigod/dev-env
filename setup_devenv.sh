#!/bin/bash

# Automatic development environment setup script

# Default directory settings
REPO_DIR=$(pwd)
EDITOR_DIR="$REPO_DIR/editor"
TERMINAL_DIR="$REPO_DIR/terminal"
HOME_DIR="$HOME"

# Default values for editor and terminal
EDITOR=""
TERMINAL=""

# Function to display help message
show_help() {
    echo "Usage: ./setup_devenv.sh -e [editor] -t [terminal tool]"
    echo ""
    echo "Options:"
    echo "  -e, --editor     Choose the editor to use (Possible values: $(list_options "$EDITOR_DIR"))"
    echo "  -t, --terminal   Choose the terminal tool to use (Possible values: $(list_options "$TERMINAL_DIR"))"
    echo "  -h, --help       Display this help message"
    exit 1
}

# Function to list available options in a given directory
list_options() {
    local dir="$1"
    if [[ -d "$dir" ]]; then
        ls "$dir" | tr '\n' ' ' | sed 's/ $//'
    else
        echo "None"
    fi
}

# Parse command-line arguments
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -e|--editor)
            if [[ -z "$2" ]]; then
                echo "Error: Missing parameter for -e/--editor"
                show_help
            fi
            EDITOR="$2"
            shift 2
            ;;
        -t|--terminal)
            if [[ -z "$2" ]]; then
                echo "Error: Missing parameter for -t/--terminal"
                show_help
            fi
            TERMINAL="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            ;;
    esac
done

# Check if either editor or terminal is specified, if neither then show help
if [[ -z "$EDITOR" && -z "$TERMINAL" ]]; then
    echo "Either editor or terminal tool must be specified."
    show_help
fi

# Check if the specified editor directory exists
if [[ -n "$EDITOR" && ! -d "$EDITOR_DIR/$EDITOR" ]]; then
    echo "Unsupported editor: $EDITOR"
    show_help
fi

# Check if the specified terminal directory exists
if [[ -n "$TERMINAL" && ! -d "$TERMINAL_DIR/$TERMINAL" ]]; then
    echo "Unsupported terminal tool: $TERMINAL"
    show_help
fi

# Function to create a symbolic link and check if the file already exists
create_symlink() {
    local src="$1"
    local dest="$2"

    if [[ -e "$dest" ]]; then
        echo "Error: '$dest' already exists. Cannot create symlink."
        exit 1
    fi

    ln -s "$src" "$dest"
    echo "Created symlink: $dest -> $src"
}

# Function to set up the chosen editor
setup_editor() {
    echo "Setting up editor ($EDITOR)"
    if [[ "$EDITOR" == "neovim" ]]; then
        mkdir -p "$HOME_DIR/.config/nvim"
        create_symlink "$EDITOR_DIR/neovim/init.lua" "$HOME_DIR/.config/nvim/init.lua"
    elif [[ "$EDITOR" == "vim" ]]; then
        create_symlink "$EDITOR_DIR/vim/.vimrc" "$HOME_DIR/.vimrc"
    fi
}

# Function to set up the chosen terminal tool
setup_terminal() {
    echo "Setting up terminal tool ($TERMINAL)"
    if [[ "$TERMINAL" == "tmux" ]]; then
        create_symlink "$TERMINAL_DIR/tmux/.tmux.conf" "$HOME_DIR/.tmux.conf"
    elif [[ "$TERMINAL" == "screen" ]]; then
        create_symlink "$TERMINAL_DIR/screen/.screenrc" "$HOME_DIR/.screenrc"
    fi
}

# Main function to execute the setup
main() {
    echo "Starting development environment setup!"

    # If editor is provided, set it up
    if [[ -n "$EDITOR" ]]; then
        setup_editor
    fi

    # If terminal is provided, set it up
    if [[ -n "$TERMINAL" ]]; then
        setup_terminal
    fi

    echo "Setup complete!"
}

# Execute the main function
main

