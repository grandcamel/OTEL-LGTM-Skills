#!/usr/bin/env bash
#
# Backup script for LGTM stack data volumes
#
# Creates compressed, timestamped backups of all telemetry data.
# Supports retention policy to automatically clean old backups.
#
# Usage:
#   ./backup.sh                      # Full backup (default)
#   ./backup.sh --quick              # Skip stopping containers (faster, less consistent)
#   ./backup.sh --component loki     # Backup single component
#   ./backup.sh --list               # List existing backups
#   ./backup.sh --restore <backup>   # Restore from backup
#   ./backup.sh --clean              # Remove old backups per retention policy
#
# Schedule via cron (daily at 2am):
#   0 2 * * * /path/to/docker-otel-lgtm/backup.sh >> /var/log/otel-backup.log 2>&1
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_DIR="$SCRIPT_DIR/container"
BACKUP_DIR="$SCRIPT_DIR/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"

# Configuration
RETENTION_DAYS=30                    # Keep backups for 30 days
COMPRESSION="gzip"                   # gzip, zstd, or none
STOP_CONTAINERS=true                 # Stop containers for consistent backup
COMPONENTS=("grafana" "prometheus" "loki" "tempo" "pyroscope")

# =============================================================================
# Argument Parsing
# =============================================================================

QUICK_MODE=false
SINGLE_COMPONENT=""
ACTION="backup"
RESTORE_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --quick|-q)
            QUICK_MODE=true
            STOP_CONTAINERS=false
            shift
            ;;
        --component|-c)
            SINGLE_COMPONENT="$2"
            shift 2
            ;;
        --list|-l)
            ACTION="list"
            shift
            ;;
        --restore|-r)
            ACTION="restore"
            RESTORE_FILE="$2"
            shift 2
            ;;
        --clean)
            ACTION="clean"
            shift
            ;;
        --retention)
            RETENTION_DAYS="$2"
            shift 2
            ;;
        --no-stop)
            STOP_CONTAINERS=false
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Backup LGTM stack data volumes."
            echo ""
            echo "Actions:"
            echo "  (default)           Create backup"
            echo "  --list, -l          List existing backups"
            echo "  --restore, -r FILE  Restore from backup file"
            echo "  --clean             Remove old backups per retention policy"
            echo ""
            echo "Options:"
            echo "  --quick, -q         Skip stopping containers (faster, less consistent)"
            echo "  --component, -c X   Backup single component (grafana, prometheus, loki, tempo, pyroscope)"
            echo "  --no-stop           Don't stop containers during backup"
            echo "  --retention DAYS    Set retention days (default: 30)"
            echo "  --help, -h          Show this help"
            echo ""
            echo "Examples:"
            echo "  $0                           # Full backup"
            echo "  $0 --quick                   # Quick backup without stopping"
            echo "  $0 --component loki          # Backup only Loki"
            echo "  $0 --list                    # Show existing backups"
            echo "  $0 --restore backups/full_20260102_120000.tar.gz"
            echo "  $0 --clean                   # Remove backups older than 30 days"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# =============================================================================
# Helper Functions
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"; }

get_size() {
    du -sh "$1" 2>/dev/null | cut -f1
}

ensure_backup_dir() {
    mkdir -p "$BACKUP_DIR"
}

is_container_running() {
    docker ps --format '{{.Names}}' | grep -q "^lgtm$"
}

stop_containers() {
    if is_container_running; then
        log_info "Stopping LGTM container for consistent backup..."
        docker-compose -f "$COMPOSE_FILE" stop
        sleep 2
    fi
}

start_containers() {
    log_info "Starting LGTM container..."
    docker-compose -f "$COMPOSE_FILE" start
}

# =============================================================================
# Backup Functions
# =============================================================================

backup_component() {
    local component="$1"
    local source_dir="$CONTAINER_DIR/$component"

    if [[ ! -d "$source_dir" ]]; then
        log_warn "Component directory not found: $source_dir"
        return 1
    fi

    local size=$(get_size "$source_dir")
    log_info "Backing up $component ($size)..."

    local backup_file="$BACKUP_DIR/${component}_${TIMESTAMP}"

    case "$COMPRESSION" in
        gzip)
            tar -czf "${backup_file}.tar.gz" -C "$CONTAINER_DIR" "$component"
            echo "${backup_file}.tar.gz"
            ;;
        zstd)
            tar -cf - -C "$CONTAINER_DIR" "$component" | zstd -q -o "${backup_file}.tar.zst"
            echo "${backup_file}.tar.zst"
            ;;
        none)
            tar -cf "${backup_file}.tar" -C "$CONTAINER_DIR" "$component"
            echo "${backup_file}.tar"
            ;;
    esac
}

do_backup() {
    ensure_backup_dir

    local components_to_backup=("${COMPONENTS[@]}")
    if [[ -n "$SINGLE_COMPONENT" ]]; then
        components_to_backup=("$SINGLE_COMPONENT")
    fi

    local was_running=false
    if is_container_running; then
        was_running=true
    fi

    # Stop containers if requested
    if [[ "$STOP_CONTAINERS" == "true" && "$was_running" == "true" ]]; then
        stop_containers
    elif [[ "$STOP_CONTAINERS" == "false" ]]; then
        log_warn "Backing up with containers running (may be inconsistent)"
    fi

    local backup_files=()
    local total_size=0

    log_info "Starting backup: $TIMESTAMP"
    log_info "Components: ${components_to_backup[*]}"
    echo ""

    for component in "${components_to_backup[@]}"; do
        if backup_file=$(backup_component "$component"); then
            backup_files+=("$backup_file")
            file_size=$(get_size "$backup_file")
            log_info "  Created: $(basename "$backup_file") ($file_size)"
        fi
    done

    # Create manifest
    local manifest_file="$BACKUP_DIR/manifest_${TIMESTAMP}.txt"
    {
        echo "LGTM Backup Manifest"
        echo "===================="
        echo "Timestamp: $TIMESTAMP"
        echo "Date: $(date)"
        echo "Components: ${components_to_backup[*]}"
        echo ""
        echo "Files:"
        for f in "${backup_files[@]}"; do
            echo "  $(basename "$f"): $(get_size "$f")"
        done
        echo ""
        echo "Source sizes:"
        for component in "${components_to_backup[@]}"; do
            if [[ -d "$CONTAINER_DIR/$component" ]]; then
                echo "  $component: $(get_size "$CONTAINER_DIR/$component")"
            fi
        done
    } > "$manifest_file"

    # Restart containers if we stopped them
    if [[ "$STOP_CONTAINERS" == "true" && "$was_running" == "true" ]]; then
        start_containers
    fi

    echo ""
    log_info "Backup complete!"
    log_info "Manifest: $manifest_file"
    log_info "Backup directory: $BACKUP_DIR"

    # Show total backup size
    local total=$(du -sh "$BACKUP_DIR" | cut -f1)
    log_info "Total backup storage used: $total"
}

# =============================================================================
# List Function
# =============================================================================

do_list() {
    ensure_backup_dir

    echo "LGTM Backups"
    echo "============"
    echo "Location: $BACKUP_DIR"
    echo ""

    if [[ ! "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]]; then
        echo "No backups found."
        return
    fi

    # Group by timestamp
    echo "Available backups:"
    echo ""

    # Find unique timestamps from manifest files
    for manifest in "$BACKUP_DIR"/manifest_*.txt; do
        if [[ -f "$manifest" ]]; then
            local ts=$(basename "$manifest" | sed 's/manifest_\(.*\)\.txt/\1/')
            local date_str=$(echo "$ts" | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/')

            echo "  $ts ($date_str)"

            # List component files for this timestamp
            for comp_file in "$BACKUP_DIR"/*_${ts}.tar*; do
                if [[ -f "$comp_file" ]]; then
                    local name=$(basename "$comp_file")
                    local size=$(get_size "$comp_file")
                    echo "    - $name ($size)"
                fi
            done
            echo ""
        fi
    done

    # Show total size
    local total=$(du -sh "$BACKUP_DIR" | cut -f1)
    echo "Total backup storage: $total"

    # Show retention info
    local old_count=$(find "$BACKUP_DIR" -name "*.tar*" -mtime +$RETENTION_DAYS 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$old_count" -gt 0 ]]; then
        echo ""
        log_warn "$old_count files older than $RETENTION_DAYS days (run --clean to remove)"
    fi
}

# =============================================================================
# Restore Function
# =============================================================================

do_restore() {
    if [[ -z "$RESTORE_FILE" ]]; then
        log_error "No backup file specified"
        echo "Usage: $0 --restore <backup-file>"
        exit 1
    fi

    if [[ ! -f "$RESTORE_FILE" ]]; then
        # Try relative to backup dir
        if [[ -f "$BACKUP_DIR/$RESTORE_FILE" ]]; then
            RESTORE_FILE="$BACKUP_DIR/$RESTORE_FILE"
        else
            log_error "Backup file not found: $RESTORE_FILE"
            exit 1
        fi
    fi

    # Extract component name from filename
    local filename=$(basename "$RESTORE_FILE")
    local component=$(echo "$filename" | sed 's/_[0-9]\{8\}_[0-9]\{6\}\.tar.*//')

    log_info "Restoring $component from $filename"

    # Confirm
    echo ""
    echo "This will OVERWRITE existing data in: $CONTAINER_DIR/$component"
    read -p "Continue? [y/N] " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Aborted."
        exit 0
    fi

    # Stop container
    local was_running=false
    if is_container_running; then
        was_running=true
        stop_containers
    fi

    # Backup current data first
    if [[ -d "$CONTAINER_DIR/$component" ]]; then
        local pre_restore_backup="$BACKUP_DIR/${component}_pre_restore_${TIMESTAMP}.tar.gz"
        log_info "Creating pre-restore backup: $pre_restore_backup"
        tar -czf "$pre_restore_backup" -C "$CONTAINER_DIR" "$component"
    fi

    # Remove existing and restore
    log_info "Removing existing $component data..."
    rm -rf "$CONTAINER_DIR/$component"

    log_info "Extracting backup..."
    case "$RESTORE_FILE" in
        *.tar.gz)
            tar -xzf "$RESTORE_FILE" -C "$CONTAINER_DIR"
            ;;
        *.tar.zst)
            zstd -d "$RESTORE_FILE" -c | tar -xf - -C "$CONTAINER_DIR"
            ;;
        *.tar)
            tar -xf "$RESTORE_FILE" -C "$CONTAINER_DIR"
            ;;
    esac

    # Restart if was running
    if [[ "$was_running" == "true" ]]; then
        start_containers
    fi

    log_info "Restore complete!"
    log_info "Restored $component from $filename"
}

# =============================================================================
# Clean Function
# =============================================================================

do_clean() {
    ensure_backup_dir

    log_info "Cleaning backups older than $RETENTION_DAYS days..."

    local count=0
    local freed=0

    # Find and remove old files
    while IFS= read -r file; do
        if [[ -f "$file" ]]; then
            local size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo 0)
            freed=$((freed + size))
            count=$((count + 1))
            log_info "  Removing: $(basename "$file")"
            rm -f "$file"
        fi
    done < <(find "$BACKUP_DIR" -name "*.tar*" -mtime +$RETENTION_DAYS 2>/dev/null)

    # Also clean old manifests
    find "$BACKUP_DIR" -name "manifest_*.txt" -mtime +$RETENTION_DAYS -delete 2>/dev/null || true

    if [[ $count -eq 0 ]]; then
        log_info "No old backups to clean."
    else
        local freed_human=$(numfmt --to=iec $freed 2>/dev/null || echo "${freed} bytes")
        log_info "Removed $count files, freed $freed_human"
    fi

    # Show remaining
    local total=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
    log_info "Remaining backup storage: $total"
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo "=============================================="
    echo "LGTM Backup Utility"
    echo "=============================================="
    echo ""

    case "$ACTION" in
        backup)
            do_backup
            ;;
        list)
            do_list
            ;;
        restore)
            do_restore
            ;;
        clean)
            do_clean
            ;;
    esac
}

main "$@"
