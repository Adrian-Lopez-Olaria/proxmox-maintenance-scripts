#!/bin/bash
# ================================================================
#  pve-update.sh
#  Actualización segura de Proxmox VE con backup previo
#  Autor: Adrián López Olaria
#  Uso manual : bash pve-update.sh
#  Uso cron   : funciona igual, detecta el modo automáticamente
# ================================================================

# ================================================================
#  CONFIGURACIÓN — Ajusta estos valores para cada empresa
# ================================================================

BACKUP_STORAGE="nombre-storage-externo"  # Nombre exacto del storage en Proxmox
                                          # (ver con: pvesm status)
BACKUP_COMPRESS="zstd"                   # Compresión: zstd (rápido) | lzo | gzip
LOG_DIR="/var/log/pve-maintenance"

# ================================================================
#  NO TOCAR A PARTIR DE AQUÍ
# ================================================================

LOG_FILE="$LOG_DIR/update-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$LOG_DIR"

# Detectar si hay alguien en la terminal o corre por cron
if [ -t 0 ]; then
    INTERACTIVE=true
else
    INTERACTIVE=false
fi

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

sep() {
    echo "----------------------------------------------------------------" | tee -a "$LOG_FILE"
}

abort() {
    log ""
    log "✗  ABORTADO: $1"
    log "   No se ha modificado nada en el sistema."
    log "   Revisa el log completo en: $LOG_FILE"
    sep
    exit 1
}

# Verificar root
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Este script debe ejecutarse como root."
    exit 1
fi

log "================================================================"
log "  INICIO: Actualización segura de Proxmox VE en $(hostname)"
if $INTERACTIVE; then
    log "  Modo: MANUAL (interactivo)"
else
    log "  Modo: AUTOMÁTICO (cron)"
fi
log "================================================================"
sep

# ================================================================
#  BLOQUE 1 — Verificar que el storage externo existe y está online
# ================================================================

log "[STORAGE] Verificando storage externo: '$BACKUP_STORAGE'..."

STORAGE_STATUS=$(pvesm status 2>/dev/null | awk -v s="$BACKUP_STORAGE" '$1==s {print $2}')

if [ -z "$STORAGE_STATUS" ]; then
    abort "El storage '$BACKUP_STORAGE' no existe en este nodo.\n   Storages disponibles:\n$(pvesm status 2>/dev/null | awk 'NR>1 {print "   - "$1" ("$2")"}')"
fi

if [ "$STORAGE_STATUS" != "active" ]; then
    abort "El storage '$BACKUP_STORAGE' existe pero no está activo (estado: $STORAGE_STATUS)."
fi

log "[STORAGE] Storage '$BACKUP_STORAGE' verificado y activo."
sep

# ================================================================
#  BLOQUE 2 — Obtener lista de VMs y CTs
# ================================================================

log "[INVENTARIO] Obteniendo lista de VMs y contenedores..."

VM_IDS=$(qm list 2>/dev/null | awk 'NR>1 {print $1}')
CT_IDS=$(pct list 2>/dev/null | awk 'NR>1 {print $1}')

VM_COUNT=$(echo "$VM_IDS" | grep -c '[0-9]' || echo 0)
CT_COUNT=$(echo "$CT_IDS" | grep -c '[0-9]' || echo 0)
TOTAL=$((VM_COUNT + CT_COUNT))

log "[INVENTARIO] VMs encontradas: $VM_COUNT"
log "[INVENTARIO] Contenedores encontrados: $CT_COUNT"
log "[INVENTARIO] Total a respaldar: $TOTAL"

if [ "$TOTAL" -eq 0 ]; then
    log "[INVENTARIO] No hay VMs ni CTs. Se omite la fase de backup."
fi

sep

# ================================================================
#  BLOQUE 3 — Backup completo de todas las VMs y CTs
# ================================================================

BACKUP_FAILED=0
BACKUP_OK=0

if [ "$TOTAL" -gt 0 ]; then
    log "[BACKUP] Iniciando backup completo en storage '$BACKUP_STORAGE'..."
    log "[BACKUP] Compresión: $BACKUP_COMPRESS | Modo: snapshot (VMs en caliente)"
    sep

    for VMID in $VM_IDS; do
        VM_NAME=$(qm config "$VMID" 2>/dev/null | grep '^name:' | awk '{print $2}')
        log "[BACKUP] Iniciando backup VM $VMID ($VM_NAME)..."
        vzdump "$VMID" --storage "$BACKUP_STORAGE" --compress "$BACKUP_COMPRESS" --mode snapshot --quiet 1 >> "$LOG_FILE" 2>&1
        if [ $? -eq 0 ]; then
            log "[BACKUP] ✓ VM $VMID ($VM_NAME) — OK"
            BACKUP_OK=$((BACKUP_OK + 1))
        else
            log "[BACKUP] ✗ VM $VMID ($VM_NAME) — FALLÓ"
            BACKUP_FAILED=$((BACKUP_FAILED + 1))
        fi
    done

    for CTID in $CT_IDS; do
        CT_NAME=$(pct config "$CTID" 2>/dev/null | grep '^hostname:' | awk '{print $2}')
        log "[BACKUP] Iniciando backup CT $CTID ($CT_NAME)..."
        vzdump "$CTID" --storage "$BACKUP_STORAGE" --compress "$BACKUP_COMPRESS" --mode snapshot --quiet 1 >> "$LOG_FILE" 2>&1
        if [ $? -eq 0 ]; then
            log "[BACKUP] ✓ CT $CTID ($CT_NAME) — OK"
            BACKUP_OK=$((BACKUP_OK + 1))
        else
            log "[BACKUP] ✗ CT $CTID ($CT_NAME) — FALLÓ"
            BACKUP_FAILED=$((BACKUP_FAILED + 1))
        fi
    done

    sep
    log "[BACKUP] Resultado: $BACKUP_OK OK | $BACKUP_FAILED fallidos de $TOTAL totales"

    if [ "$BACKUP_FAILED" -gt 0 ]; then
        abort "$BACKUP_FAILED backup(s) fallaron. No es seguro actualizar."
    fi

    log "[BACKUP] Todos los backups completados. Procediendo con la actualización."
    sep
fi

# ================================================================
#  BLOQUE 4 — Actualización del sistema
# ================================================================

log "[UPDATE] Actualizando lista de repositorios..."
apt-get update -qq >> "$LOG_FILE" 2>&1
if [ $? -ne 0 ]; then
    abort "Falló 'apt update'. Comprueba los repositorios en /etc/apt/sources.list"
fi

UPGRADABLE=$(apt list --upgradable 2>/dev/null | grep -c '\[upgradable\]')
log "[UPDATE] Paquetes pendientes de actualización: $UPGRADABLE"

if [ "$UPGRADABLE" -eq 0 ]; then
    log "[UPDATE] El sistema ya está actualizado. No hay nada que hacer."
    sep
else
    log "[UPDATE] Aplicando actualizaciones..."
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq >> "$LOG_FILE" 2>&1

    if [ $? -ne 0 ]; then
        log ""
        log "✗  ERROR: La actualización falló a medias."
        log "   Los backups están disponibles en el storage '$BACKUP_STORAGE'."
        log "   Restaura manualmente desde la interfaz web de Proxmox si es necesario."
        log "   Log completo en: $LOG_FILE"
        sep
        exit 1
    fi

    log "[UPDATE] Actualizaciones aplicadas correctamente."
fi

sep

# ================================================================
#  BLOQUE 5 — Limpieza post-actualización
# ================================================================

log "[LIMPIEZA] Eliminando paquetes huérfanos..."
apt-get autoremove -y -qq >> "$LOG_FILE" 2>&1
apt-get autoclean -qq >> "$LOG_FILE" 2>&1
log "[LIMPIEZA] Limpieza completada."
sep

# ================================================================
#  BLOQUE 6 — Reinicio: interactivo vs automático
# ================================================================

log "[REINICIO] Comprobando si se requiere reinicio del sistema..."

if [ -f /var/run/reboot-required ]; then

    log ""
    log "⚠  El sistema requiere reinicio tras la actualización."
    log "   Paquetes que lo requieren:"
    cat /var/run/reboot-required.pkgs 2>/dev/null | while read pkg; do
        log "   - $pkg"
    done
    log ""

    if $INTERACTIVE; then
        # Modo manual: pregunta al administrador
        echo ""
        echo "========================================================"
        echo "  ⚠  Se requiere reinicio del sistema."
        echo "========================================================"
        echo "  [1] Reiniciar ahora automáticamente"
        echo "  [0] Reiniciar manualmente más tarde"
        echo "========================================================"
        read -r -p "  Tu elección (1/0): " REBOOT_CHOICE

        if [ "$REBOOT_CHOICE" = "1" ]; then
            log "[REINICIO] Administrador eligió reinicio inmediato."
            log "[REINICIO] Reiniciando en 10 segundos... (Ctrl+C para cancelar)"
            echo ""
            echo "  Reiniciando en 10 segundos... (Ctrl+C para cancelar)"
            sleep 10
            log "[REINICIO] Ejecutando reboot..."
            reboot
        else
            log "[REINICIO] Administrador eligió reinicio manual. Reinicia cuando sea seguro: reboot"
            echo "  OK. Recuerda reiniciar manualmente cuando no haya actividad."
        fi

    else
        # Modo cron: anota en el log, no hace nada solo
        log "[REINICIO] Modo automático (cron): NO se reinicia solo."
        log "[REINICIO] Conéctate al nodo y ejecuta 'reboot' cuando sea seguro."
        log "[REINICIO] O ejecuta el script manualmente para que te pregunte: bash $0"
    fi

else
    log "[REINICIO] No se requiere reinicio."
fi

sep

# ================================================================
#  RESUMEN FINAL
# ================================================================

log "================================================================"
log "  FIN: Actualización completada en $(hostname)"
log "  Backups guardados en  : $BACKUP_STORAGE"
log "  Paquetes actualizados : $UPGRADABLE"
log "  Backups realizados    : $BACKUP_OK de $TOTAL"
log "  Log guardado en       : $LOG_FILE"
log "================================================================"