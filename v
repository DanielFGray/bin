#!/usr/bin/env bash

usage() {
    less -FEXR <<'EOF'
v [OPTIONS] [FILES]
tmux window-aware neovim server manager

OPTIONS:
  -h  --help  Show this help
  -d          Disable focusing on vim pane

BEHAVIOR:
  - Each tmux window gets its own nvim server instance
  - Running 'v' without files in existing nvim window shows file picker (fv)
  - Different tmux windows maintain separate nvim instances
  - Server names are serialized from tmux session+window info
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

has() {
    command -v "$1" >/dev/null 2>&1
}

get_server_name() {
    if [[ -z "${TMUX:-}" ]]; then
        echo "/tmp/nvim-standalone"
        return
    fi

    local session window
    session=$(tmux display-message -p '#S')
    window=$(tmux display-message -p '#I')

    # Sanitize session name for filesystem
    session=${session//[^a-zA-Z0-9_-]/_}

    echo "/tmp/nvim-${session}-${window}"
}

server_exists() {
    local server_name="$1"
    [[ -S "$server_name" ]]
}

start_nvim_server() {
    local server_name="$1"
    shift

    if [[ -n "${TMUX:-}" ]]; then
        # Set window title to indicate nvim
        tmux rename-window 'nvim' 2>/dev/null || true
    fi

    # Start nvim with server listening
    exec nvim --listen "$server_name" "$@"
}

connect_to_server() {
    local server_name="$1"
    shift

    if (($# == 0)); then
        # No files specified - show file picker
        if ! has fzf; then
            die "fzf not found - cannot show file picker"
        fi
        exec fzf \
            --preview='bat -fp {}' \
            --preview-window=60% \
            --bind='start:reload:fd --color=always' \
            --bind="enter:execute:$0 {}"
    else
        # Open files in existing server
        for file in "$@"; do
            # Convert relative paths to absolute paths
            if [[ "$file" = /* ]]; then
                abs_file="$file"
            else
                abs_file="$PWD/$file"
            fi
            nvim --server "$server_name" --remote-send "<Esc>:e $abs_file<CR>"
        done
    fi

    focus_nvim_pane "$server_name"
}

focus_nvim_pane() {
    local server_name="$1"

    # Try to get the tmux pane from nvim
    local pane
    if pane=$(nvim --server "$server_name" --remote-expr 'v:servername' 2>/dev/null); then
        tmux select-pane -t "$pane" 2>/dev/null || true
    else
        # Fallback: find pane running nvim
        local nvim_pane
        nvim_pane=$(tmux list-panes -F '#{pane_id} #{pane_current_command}' |
            awk '$2 == "nvim" {print $1; exit}')
        if [[ -n "$nvim_pane" ]]; then
            tmux select-pane -t "$nvim_pane"
        fi
    fi
}

main() {
    # Check dependencies
    has nvim || die "neovim not found"

    # Parse arguments
    local files=()

    while (($# > 0)); do
        case "$1" in
        -h | --help)
            usage
            exit 0
            ;;
        -d)
            export FOCUS_DISABLE=1
            ;;
        --)
            shift
            files+=("$@")
            break
            ;;
        -*)
            die "Unknown option: $1"
            ;;
        *)
            files+=("$1")
            ;;
        esac
        shift
    done

    local server_name
    server_name=$(get_server_name)

    if server_exists "$server_name"; then
        # Server exists for this tmux window - connect to it
        connect_to_server "$server_name" "${files[@]}"
    else
        # No server for this window - start new instance
        start_nvim_server "$server_name" "${files[@]}"
    fi
}

main "$@"
