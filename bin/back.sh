
#!/usr/bin/env bash

set -Eeuo pipefail

VIRSH_URI="qemu:///system"

BACKUP_DIR="${VM_BACKUP_DIR:-$HOME/vmBack}"
MOUNT_DIR="${VM_MOUNT_DIR:-$HOME/vm-mount}"

# -------------------------
# Общие функции
# -------------------------

error() {
    echo "[ERROR] $*" >&2
    exit 1
}

log() {
    echo "[INFO] $*"
}

check_args() {
    local option="$1"
    local required="$2"
    shift 2

    if (( $# < required )); then
        error "Not enough arguments for $option"
    fi

    local i
    for ((i=1; i<=required; i++)); do
        [[ "${!i}" != --* ]] ||
            error "Missing argument for $option"
    done
}

check_vm_name() {
    local vm="$1"

    [[ "$vm" =~ ^[a-zA-Z0-9_.-]+$ ]] ||
        error "Invalid VM name: $vm"

    [[ "$vm" != "." && "$vm" != ".." ]] ||
        error "Invalid VM name"
}

# -------------------------
# Копирование директории
# -------------------------

copy_repo() {
    local source="$1"

    [[ -d "$source" ]] ||
        error "Directory not found: $source"

    cp -a -- "$source" . ||
        error "Copy failed"

    log "Directory copied successfully"
}

# -------------------------
# Список виртуальных машин
# -------------------------

vm_list() {
    sudo virsh -c "$VIRSH_URI" list --all
}

# -------------------------
# Список дисков VM
# -------------------------

vm_disks() {
    local vm="$1"

    check_vm_name "$vm"

    sudo virsh -c "$VIRSH_URI" \
        domblklist "$vm" --details
}

# -------------------------
# Монтирование файловой системы VM
# -------------------------

vm_mount() {
    local vm="$1"
    local mount_point="$MOUNT_DIR/$vm"

    check_vm_name "$vm"

    sudo mkdir -p "$mount_point"

    if mountpoint -q "$mount_point"; then
        error "Already mounted: $mount_point"
    fi

    sudo guestmount \
        -c "$VIRSH_URI" \
        -d "$vm" \
        -i --ro "$mount_point" ||
        error "Mount failed: $vm"

    log "Mounted: $mount_point"
}

# -------------------------
# Размонтирование VM
# -------------------------

vm_unmount() {
    local vm="$1"
    local mount_point="$MOUNT_DIR/$vm"

    check_vm_name "$vm"

    sudo guestunmount "$mount_point" ||
        error "Unmount failed: $vm"

    log "Unmounted: $mount_point"
}

# -------------------------
# Получение IP VM
# -------------------------

get_vm_ip() {
    local vm="$1"
    local ip=""

    ip=$(
        sudo virsh -c "$VIRSH_URI" \
            domifaddr "$vm" --source agent 2>/dev/null |
        awk '$3 == "ipv4" {
            split($4, a, "/")
            print a[1]
            exit
        }'
    ) || true

    if [[ -z "$ip" ]]; then
        ip=$(
            sudo virsh -c "$VIRSH_URI" \
                domifaddr "$vm" --source lease 2>/dev/null |
            awk '$3 == "ipv4" {
                split($4, a, "/")
                print a[1]
                exit
            }'
        ) || true
    fi

    [[ -n "$ip" ]] ||
        error "Cannot determine IP for VM: $vm"

    echo "$ip"
}

# -------------------------
# Копирование по сети
# -------------------------

net_backup() {
    local vm="$1"
    local user="$2"
    local directory="$3"
    local ip
    local target

    check_vm_name "$vm"

    [[ "$user" =~ ^[a-zA-Z0-9_.-]+$ ]] ||
        error "Invalid SSH username"

    ip=$(get_vm_ip "$vm")
    target="$BACKUP_DIR/$vm"

    mkdir -p "$target"

    log "VM: $vm"
    log "IP: $ip"
    log "Source: $directory"

    scp -r "${user}@${ip}:${directory}" "$target/" ||
        error "SCP backup failed"

    log "Backup saved: $target"
}

# -------------------------
# Архивирование
# -------------------------

compression() {
    local source="$1"
    local name
    local timestamp
    local archive
    local source_abs
    local archive_dir="$BACKUP_DIR/archives"

    [[ -e "$source" ]] ||
        error "Source not found: $source"

    source_abs=$(realpath -- "$source")
    mkdir -p "$archive_dir"

    archive_dir=$(realpath -- "$archive_dir")

    # Не архивируем папку вместе с создаваемым
    # внутри неё архивом.
    case "$archive_dir/" in
        "$source_abs/"*)
            error "Archive destination is inside source"
            ;;
    esac

    name=$(basename -- "$source_abs")
    timestamp=$(date +%Y%m%d_%H%M%S_%N)
    archive="$archive_dir/${name}_${timestamp}.tar.gz"

    tar -czf "$archive" \
        -C "$(dirname -- "$source_abs")" \
        -- "$name" ||
        error "Compression failed"

    log "Archive created: $archive"
}

# -------------------------
# Справка
# -------------------------

show_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -l, --vm-list                 List all VMs
  -d, --vm-disks VM             Show VM disks
  -m, --vm-mount VM             Mount VM read-only
  -u, --vm-unmount VM           Unmount VM
  -n, --net-back VM USER PATH   Copy files from VM
  -c, --copy-repo PATH          Copy directory locally
  -z, --compress PATH           Create tar.gz archive
  -h, --help                    Show this help

Examples:
  $0 --vm-list
  $0 --vm-disks ubuntu
  $0 --net-back ubuntu user /home/user/data
  $0 --compress /tmp/data
  $0 --vm-list --vm-disks ubuntu
EOF
}

# -------------------------
# Обработка аргументов
# -------------------------

main() {
    if (( $# == 0 )); then
        show_help
        return 0
    fi

    while (( $# > 0 )); do
        case "$1" in

            -l|--vm-list)
                vm_list
                shift
                ;;

            -d|--vm-disks)
                check_args "$1" 1 "${@:2}"
                vm_disks "$2"
                shift 2
                ;;

            -m|--vm-mount)
                check_args "$1" 1 "${@:2}"
                vm_mount "$2"
                shift 2
                ;;

            -u|--vm-unmount)
                check_args "$1" 1 "${@:2}"
                vm_unmount "$2"
                shift 2
                ;;

            -n|--net-back)
                check_args "$1" 3 "${@:2}"
                net_backup "$2" "$3" "$4"
                shift 4
                ;;

            -c|--copy-repo)
                check_args "$1" 1 "${@:2}"
                copy_repo "$2"
                shift 2
                ;;

            -z|--compress)
                check_args "$1" 1 "${@:2}"
                compression "$2"
                shift 2
                ;;

            -h|--help)
                show_help
                shift
                ;;

            *)
                error "Unknown option: $1"
                ;;
        esac
    done
}

main "$@"

