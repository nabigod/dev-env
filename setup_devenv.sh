#!/bin/bash

# Automatic development environment setup script

# Default directory settings
REPO_DIR=$(pwd)
EDITOR_DIR="$REPO_DIR/editor"
TERMINAL_DIR="$REPO_DIR/terminal"
HOME_DIR="$HOME"
FORCE=false  # Default value for force option
VERBOSE=false  # Default value for verbose option

# Default values for editor and terminal
EDITOR=""
TERMINAL=""

# Function to display help message
show_help() {
    echo "Usage: ./setup_devenv.sh -e [editor] -t [terminal tool] [-f] [-v]"
    echo ""
    echo "Options:"
    echo "  -e, --editor     Choose the editor to use (Possible values: $(list_options "$EDITOR_DIR"))"
    echo "  -t, --terminal   Choose the terminal tool to use (Possible values: $(list_options "$TERMINAL_DIR"))"
    echo "  -f, --force      Force create symbolic links by deleting existing files"
    echo "  -v, --verbose    Enable verbose output (detailed logs)"
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
        -f|--force)
            FORCE=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            show_help
            ;;
        *)
            echo "Error: Unknown option: $1"
            show_help
            ;;
    esac
done

# Check if either editor or terminal is specified, if neither then show help
if [[ -z "$EDITOR" && -z "$TERMINAL" ]]; then
    echo "Error: You must specify either an editor or terminal tool."
    show_help
fi

# Check if the specified editor directory exists
if [[ -n "$EDITOR" && ! -d "$EDITOR_DIR/$EDITOR" ]]; then
    echo "Error: Unsupported editor '$EDITOR'. Available options: $(list_options "$EDITOR_DIR")"
    show_help
fi

# Check if the specified terminal directory exists
if [[ -n "$TERMINAL" && ! -d "$TERMINAL_DIR/$TERMINAL" ]]; then
    echo "Error: Unsupported terminal tool '$TERMINAL'. Available options: $(list_options "$TERMINAL_DIR")"
    show_help
fi

# Function to create a symbolic link and check if the file already exists
create_symlink() {
    local src="$1"
    local dest="$2"

    if [[ -e "$dest" ]]; then
        if [[ "$FORCE" == true ]]; then
            if [[ "$VERBOSE" == true ]]; then
                echo "  [INFO] Force option enabled: Deleting existing file '$dest'."
            fi
            rm -f "$dest"  # Delete the existing file
        else
            echo "  [ERROR] '$dest' already exists. Use -f option to force delete and create symlink."
            exit 1
        fi
    fi

    ln -s "$src" "$dest"

    if [[ "$VERBOSE" == true ]]; then
        echo "  [SUCCESS] Created symlink: $dest -> $src"
    fi
}

# Function to set up the chosen editor
setup_editor() {
    if [[ "$VERBOSE" == true ]]; then
        echo "[INFO] Setting up editor: $EDITOR"
    fi
    if [[ "$EDITOR" == "neovim" ]]; then
        mkdir -p "$HOME_DIR/.config/nvim"
        create_symlink "$EDITOR_DIR/neovim/init.lua" "$HOME_DIR/.config/nvim/init.lua"
    elif [[ "$EDITOR" == "vim" ]]; then
        create_symlink "$EDITOR_DIR/vim/.vimrc" "$HOME_DIR/.vimrc"
    fi
}

# Function to set up the chosen terminal tool
setup_terminal() {
    if [[ "$VERBOSE" == true ]]; then
        echo "[INFO] Setting up terminal tool: $TERMINAL"
    fi
    if [[ "$TERMINAL" == "tmux" ]]; then
        create_symlink "$TERMINAL_DIR/tmux/.tmux.conf" "$HOME_DIR/.tmux.conf"
    elif [[ "$TERMINAL" == "screen" ]]; then
        create_symlink "$TERMINAL_DIR/screen/.screenrc" "$HOME_DIR/.screenrc"
    fi
}

# Main function to execute the setup
main() {
    if [[ "$VERBOSE" == true ]]; then
        echo "[INFO] Starting development environment setup..."
    fi

    # If editor is provided, set it up
    if [[ -n "$EDITOR" ]]; then
        setup_editor
    fi

    # If terminal is provided, set it up
    if [[ -n "$TERMINAL" ]]; then
        setup_terminal
    fi

    if [[ "$VERBOSE" == true ]]; then
        echo "[INFO] Setup complete!"
    fi
}

# Execute the main function
main
