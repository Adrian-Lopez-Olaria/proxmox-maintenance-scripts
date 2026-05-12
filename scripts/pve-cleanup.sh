#!/bin/bash
# ================================================================
#  pve-cleanup.sh
#  Limpieza automática de Proxmox VE
#  Autor: Adrián López Olaria
#  Uso:   bash pve-cleanup.sh
# ================================================================

# ================================================================
#  CONFIGURACIÓN — Ajusta estos valores para cada empresa
# ================================================================

BACKUP_DIR="/var/lib/vz/dump"   # Ruta donde Proxmox guarda los backups
BACKUP_RETENTION_DAYS=90        # Borrar backups más viejos de X días
JOURNAL_MAX_SIZE="500M"         # Tamaño máximo del journal del sistema
DISK_WARN_PERCENT=85            # Porcentaje de disco que activa la alerta
LOG_DIR="/var/log/pve-maintenance"

# ================================================================
#  NO TOCAR A PARTIR DE AQUÍ
# ================================================================

LOG_FILE="$LOG_DIR/cleanup-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$LOG_DIR"

SPACE_BEFORE=0
SPACE_AFTER=0

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

sep() {
    echo "----------------------------------------------------------------" | tee -a "$LOG_FILE"
}

disk_free_mb() {
    df / | awk 'NR==2 {print int($4/1024)}'
}

# Verificar root
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Este script debe ejecutarse como root."
    exit 1
fi

SPACE_BEFORE=$(disk_free_mb)

log "================================================================"
log "  INICIO: Limpieza de Proxmox VE en $(hostname)"
log "  Espacio libre al inicio: ${SPACE_BEFORE} MB"
log "================================================================"
sep

# ================================================================
#  BLOQUE 1 — Detección del tipo de storage
# ================================================================

log "[STORAGE] Detectando tipo de almacenamiento..."

HAS_ZFS=false
HAS_LVM=false
HAS_DIR=false

if command -v zpool &>/dev/null && zpool list &>/dev/null 2>&1; then
    HAS_ZFS=true
    log "[STORAGE] ZFS detectado."
fi

if command -v lvs &>/dev/null && lvs &>/dev/null 2>&1; then
    HAS_LVM=true
    log "[STORAGE] LVM / LVM-Thin detectado."
fi

if [ -d "/var/lib/vz" ]; then
    HAS_DIR=true
    log "[STORAGE] Directory storage detectado (/var/lib/vz)."
fi

sep

# ================================================================
#  BLOQUE 2 — Limpieza del journal del sistema
# ================================================================

log "[JOURNAL] Limpiando journal del sistema (límite: $JOURNAL_MAX_SIZE, máx. 90 días)..."

JOURNAL_BEFORE=$(du -sh /var/log/journal 2>/dev/null | cut -f1)
journalctl --vacuum-size="$JOURNAL_MAX_SIZE" >> "$LOG_FILE" 2>&1
journalctl --vacuum-time=90d >> "$LOG_FILE" 2>&1
JOURNAL_AFTER=$(du -sh /var/log/journal 2>/dev/null | cut -f1)

log "[JOURNAL] Tamaño antes: ${JOURNAL_BEFORE:-desconocido} → después: ${JOURNAL_AFTER:-desconocido}"
sep

# ================================================================
#  BLOQUE 3 — Rotación de logs generales
# ================================================================

log "[LOGS] Forzando rotación de logs del sistema..."
logrotate -f /etc/logrotate.conf >> "$LOG_FILE" 2>&1
log "[LOGS] Rotación completada."
sep

# ================================================================
#  BLOQUE 4 — Backups viejos
# ================================================================

log "[BACKUPS] Buscando backups con más de ${BACKUP_RETENTION_DAYS} días en: $BACKUP_DIR"

if [ -d "$BACKUP_DIR" ]; then
    OLD_FILES=$(find "$BACKUP_DIR" -type f \( \
        -name "*.tar.gz" -o -name "*.tar.lzo" -o \
        -name "*.tar.zst" -o -name "*.vma.gz"  -o \
        -name "*.vma.zst" \) -mtime "+$BACKUP_RETENTION_DAYS")

    if [ -z "$OLD_FILES" ]; then
        log "[BACKUPS] No hay backups antiguos que eliminar."
    else
        COUNT=$(echo "$OLD_FILES" | wc -l)
        SIZE=$(echo "$OLD_FILES" | xargs du -ch 2>/dev/null | tail -1 | cut -f1)
        log "[BACKUPS] Eliminando $COUNT archivo(s) — espacio recuperado: ~$SIZE"
        echo "$OLD_FILES" | xargs rm -f
        log "[BACKUPS] Eliminación completada."
    fi

    OLD_LOGS=$(find "$BACKUP_DIR" -name "*.log" -mtime "+$BACKUP_RETENTION_DAYS")
    if [ -n "$OLD_LOGS" ]; then
        LOG_COUNT=$(echo "$OLD_LOGS" | wc -l)
        echo "$OLD_LOGS" | xargs rm -f
        log "[BACKUPS] $LOG_COUNT log(s) de backup antiguos eliminados."
    fi
else
    log "[BACKUPS] AVISO: Directorio de backups no encontrado: $BACKUP_DIR"
    log "[BACKUPS] Revisa la variable BACKUP_DIR en la configuración del script."
fi
sep

# ================================================================
#  BLOQUE 5 — Limpieza específica por tipo de storage
# ================================================================

if $HAS_ZFS; then
    log "[ZFS] Ejecutando trim en pools ZFS..."
    zpool list -H -o name 2>/dev/null | while read pool; do
        zpool trim "$pool" >> "$LOG_FILE" 2>&1
        log "[ZFS] Trim lanzado en pool: $pool"
    done
    log "[ZFS] Estado de los pools:"
    zpool status 2>/dev/null | grep -E "pool:|state:|errors:" | while read line; do
        log "[ZFS]   $line"
    done
fi

if $HAS_LVM; then
    log "[LVM] Ejecutando fstrim en volúmenes montados..."
    fstrim -av >> "$LOG_FILE" 2>&1
    log "[LVM] fstrim completado."
    if lvs --noheadings -o lv_name,data_percent,metadata_percent 2>/dev/null | grep -q "%"; then
        log "[LVM] Uso de thin pools:"
        lvs --noheadings -o lv_name,data_percent,metadata_percent 2>/dev/null | while read line; do
            log "[LVM]   $line"
        done
    fi
fi

if $HAS_DIR; then
    log "[DIR] Comprobando espacio en /var/lib/vz..."
    VZ_USAGE=$(df -h /var/lib/vz | awk 'NR==2 {print "Usado: "$3" de "$2" ("$5" ocupado)"}')
    log "[DIR] $VZ_USAGE"
fi

sep

# ================================================================
#  BLOQUE 6 — Paquetes residuales de apt
# ================================================================

log "[APT] Limpiando paquetes residuales..."
apt-get autoremove -y -qq >> "$LOG_FILE" 2>&1
apt-get autoclean -qq >> "$LOG_FILE" 2>&1
log "[APT] Limpieza de apt completada."
sep

# ================================================================
#  BLOQUE 7 — Comprobación de disco y alerta si supera el umbral
# ================================================================

DISK_PERCENT=$(df / | awk 'NR==2 {print int($5)}')
SPACE_AFTER=$(disk_free_mb)
SPACE_FREED=$((SPACE_BEFORE - SPACE_AFTER))
if [ $SPACE_FREED -lt 0 ]; then SPACE_FREED=0; fi

log "[DISCO] Uso actual del disco raíz: ${DISK_PERCENT}%"
log "[DISCO] Espacio libre al finalizar: ${SPACE_AFTER} MB"
log "[DISCO] Espacio aproximado liberado: ${SPACE_FREED} MB"

if [ "$DISK_PERCENT" -ge "$DISK_WARN_PERCENT" ]; then
    log ""
    log "⚠  ALERTA: El disco sigue por encima del ${DISK_WARN_PERCENT}% tras la limpieza (${DISK_PERCENT}% en uso)."
    log "   Acciones manuales recomendadas:"
    log "   - Revisar snapshots de VMs y CTs sin usar: qm listsnapshot <vmid>"
    log "   - Eliminar ISOs antiguas en /var/lib/vz/template/iso"
    log "   - Reducir BACKUP_RETENTION_DAYS en este script si hace falta"
    log "   - Comprobar si alguna VM tiene disco aprovisionado en exceso"
fi

sep

# ================================================================
#  RESUMEN FINAL
# ================================================================

log "================================================================"
log "  FIN: Limpieza completada en $(hostname)"
log "  Espacio libre antes : ${SPACE_BEFORE} MB"
log "  Espacio libre ahora : ${SPACE_AFTER} MB"
log "  Espacio liberado    : ~${SPACE_FREED} MB"
log "  Log guardado en     : $LOG_FILE"
log "================================================================"