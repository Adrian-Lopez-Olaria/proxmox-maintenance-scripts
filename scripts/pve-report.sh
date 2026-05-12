#!/bin/bash
# ================================================================
#  pve-report.sh
#  Reporte diario de estado de Proxmox VE por correo
#  Autor: Adrián López Olaria
#  Uso:   bash pve-report.sh
#  Cron:  0 11 * * * /usr/local/bin/pve-report.sh
# ================================================================
 
# ================================================================
#  CONFIGURACIÓN — Ajusta estos valores para cada empresa
# ================================================================
 
SMTP_HOST="smtp.gmail.com"
SMTP_PORT="465"
SMTP_USER="tu-cuenta@gmail.com"
SMTP_PASS="XXXX XXXX XXXX XXXX"  # Ver instrucciones abajo
 
MAIL_FROM="tu-cuenta@gmail.com"
MAIL_TO="usuario1@empresa.com usuario2@empresa.com"  # Separados por espacio
 
WARN_PERCENT=85       # Umbral para resaltar en rojo (disco, RAM, CPU)
LOG_DIR="/var/log/pve-maintenance"
 
# ================================================================
#  NO TOCAR A PARTIR DE AQUÍ
# ================================================================
 
LOG_FILE="$LOG_DIR/report-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$LOG_DIR"
 
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}
 
# Verificar root
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Este script debe ejecutarse como root."
    exit 1
fi
 
# Verificar que msmtp está instalado
if ! command -v msmtp &>/dev/null; then
    log "ERROR: msmtp no está instalado. Ejecuta: apt-get install -y msmtp msmtp-mta"
    exit 1
fi
 
log "================================================================"
log "  INICIO: Generando reporte de estado en $(hostname)"
log "================================================================"
 
# ================================================================
#  RECOGER DATOS
# ================================================================
 
HOSTNAME=$(hostname)
DATE_NOW=$(date '+%A, %d de %B de %Y — %H:%M')
 
# CPU
CPU_MODEL=$(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)
CPU_CORES=$(nproc)
CPU_LOAD=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1 | tr -d ' ')
# Redondear CPU a entero
CPU_LOAD=$(printf "%.0f" "$CPU_LOAD" 2>/dev/null || echo "0")
 
# RAM
RAM_TOTAL_MB=$(free -m | awk '/^Mem:/{print $2}')
RAM_USED_MB=$(free -m | awk '/^Mem:/{print $3}')
RAM_PERCENT=$(free | awk '/^Mem:/{printf "%.0f", $3/$2*100}')
RAM_TOTAL_H=$(free -h | awk '/^Mem:/{print $2}')
RAM_USED_H=$(free -h | awk '/^Mem:/{print $3}')
 
# DISCO
DISK_PERCENT=$(df / | awk 'NR==2 {print int($5)}')
DISK_USED=$(df -h / | awk 'NR==2 {print $3}')
DISK_TOTAL=$(df -h / | awk 'NR==2 {print $2}')
DISK_FREE=$(df -h / | awk 'NR==2 {print $4}')
 
# VMs y CTs
VM_TOTAL=$(qm list 2>/dev/null | tail -n +2 | wc -l)
VM_RUNNING=$(qm list 2>/dev/null | grep -i running | wc -l)
CT_TOTAL=$(pct list 2>/dev/null | tail -n +2 | wc -l)
CT_RUNNING=$(pct list 2>/dev/null | grep -i running | wc -l)
 
# Actualizaciones pendientes
apt-get update -qq 2>/dev/null
UPGRADABLE=$(apt list --upgradable 2>/dev/null | grep -c '\[upgradable\]')
 
log "[DATOS] CPU: ${CPU_LOAD}% | RAM: ${RAM_PERCENT}% | Disco: ${DISK_PERCENT}%"
 
# ================================================================
#  FUNCIÓN: color según umbral
# ================================================================
 
color_for() {
    local VALUE=$1
    if [ "$VALUE" -ge "$WARN_PERCENT" ]; then
        echo "#c0392b"   # rojo
    elif [ "$VALUE" -ge 70 ]; then
        echo "#e67e22"   # naranja
    else
        echo "#27ae60"   # verde
    fi
}
 
COLOR_CPU=$(color_for "$CPU_LOAD")
COLOR_RAM=$(color_for "$RAM_PERCENT")
COLOR_DISK=$(color_for "$DISK_PERCENT")
 
# ================================================================
#  CONSTRUIR CORREO HTML
# ================================================================
 
SUBJECT="[Proxmox] Reporte diario — $HOSTNAME — $(date '+%d/%m/%Y')"
 
HTML_BODY=$(cat <<HTML
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<style>
  body { font-family: Arial, sans-serif; background: #f4f4f4; margin: 0; padding: 20px; }
  .container { max-width: 600px; margin: auto; background: #ffffff; border-radius: 8px; overflow: hidden; box-shadow: 0 2px 8px rgba(0,0,0,0.1); }
  .header { background: #2c3e50; color: white; padding: 24px 28px; }
  .header h1 { margin: 0; font-size: 20px; }
  .header p { margin: 6px 0 0; font-size: 13px; color: #bdc3c7; }
  .section { padding: 20px 28px; border-bottom: 1px solid #ecf0f1; }
  .section h2 { margin: 0 0 14px; font-size: 14px; text-transform: uppercase; color: #7f8c8d; letter-spacing: 1px; }
  .metric { display: flex; justify-content: space-between; align-items: center; margin-bottom: 12px; }
  .metric-label { font-size: 14px; color: #555; }
  .metric-value { font-size: 14px; font-weight: bold; }
  .bar-wrap { background: #ecf0f1; border-radius: 4px; height: 8px; width: 200px; overflow: hidden; }
  .bar-fill { height: 8px; border-radius: 4px; }
  .badge { display: inline-block; padding: 3px 10px; border-radius: 12px; font-size: 12px; font-weight: bold; color: white; }
  .badge-green { background: #27ae60; }
  .badge-orange { background: #e67e22; }
  .badge-red { background: #c0392b; }
  .info-row { display: flex; justify-content: space-between; font-size: 13px; color: #555; margin-bottom: 8px; }
  .footer { padding: 16px 28px; background: #f9f9f9; font-size: 12px; color: #aaa; text-align: center; }
</style>
</head>
<body>
<div class="container">
 
  <div class="header">
    <h1>📊 Reporte diario — $HOSTNAME</h1>
    <p>$DATE_NOW</p>
  </div>
 
  <!-- CPU -->
  <div class="section">
    <h2>CPU</h2>
    <div class="metric">
      <span class="metric-label">$CPU_MODEL ($CPU_CORES núcleos)</span>
    </div>
    <div class="metric">
      <span class="metric-label">Uso actual</span>
      <span class="metric-value" style="color: $COLOR_CPU;">${CPU_LOAD}%</span>
    </div>
    <div class="bar-wrap">
      <div class="bar-fill" style="width: ${CPU_LOAD}%; background: $COLOR_CPU;"></div>
    </div>
  </div>
 
  <!-- RAM -->
  <div class="section">
    <h2>Memoria RAM</h2>
    <div class="metric">
      <span class="metric-label">Usada: $RAM_USED_H de $RAM_TOTAL_H</span>
      <span class="metric-value" style="color: $COLOR_RAM;">${RAM_PERCENT}%</span>
    </div>
    <div class="bar-wrap">
      <div class="bar-fill" style="width: ${RAM_PERCENT}%; background: $COLOR_RAM;"></div>
    </div>
  </div>
 
  <!-- DISCO -->
  <div class="section">
    <h2>Disco ( / )</h2>
    <div class="metric">
      <span class="metric-label">Usado: $DISK_USED de $DISK_TOTAL — Libre: $DISK_FREE</span>
      <span class="metric-value" style="color: $COLOR_DISK;">${DISK_PERCENT}%</span>
    </div>
    <div class="bar-wrap">
      <div class="bar-fill" style="width: ${DISK_PERCENT}%; background: $COLOR_DISK;"></div>
    </div>
  </div>
 
  <!-- VMs y CTs -->
  <div class="section">
    <h2>Máquinas virtuales y contenedores</h2>
    <div class="info-row"><span>VMs totales</span><strong>$VM_TOTAL</strong></div>
    <div class="info-row"><span>VMs en ejecución</span><strong>$VM_RUNNING</strong></div>
    <div class="info-row"><span>Contenedores totales</span><strong>$CT_TOTAL</strong></div>
    <div class="info-row"><span>Contenedores en ejecución</span><strong>$CT_RUNNING</strong></div>
  </div>
 
  <!-- Actualizaciones -->
  <div class="section">
    <h2>Actualizaciones del sistema</h2>
    <div class="metric">
      <span class="metric-label">Paquetes pendientes</span>
      $(if [ "$UPGRADABLE" -gt 0 ]; then
          echo "<span class=\"badge badge-orange\">$UPGRADABLE pendientes</span>"
        else
          echo "<span class=\"badge badge-green\">Al día</span>"
        fi)
    </div>
  </div>
 
  <div class="footer">
    Generado automáticamente por pve-report.sh · $HOSTNAME · $(date '+%d/%m/%Y %H:%M')
  </div>
 
</div>
</body>
</html>
HTML
)
 
# ================================================================
#  ENVIAR CORREO con msmtp
# ================================================================
 
MSMTP_CONF="/etc/msmtprc"
 
# Crear configuración de msmtp si no existe o está desactualizada
cat > "$MSMTP_CONF" <<MSMTPCONF
defaults
auth           on
tls            on
tls_starttls   off
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        $LOG_DIR/msmtp.log
 
account        gmail
host           $SMTP_HOST
port           $SMTP_PORT
from           $MAIL_FROM
user           $SMTP_USER
password       $SMTP_PASS
 
account default : gmail
MSMTPCONF
 
chmod 600 "$MSMTP_CONF"
 
log "[CORREO] Enviando reporte a: $MAIL_TO"
 
for RECIPIENT in $MAIL_TO; do
    {
        echo "From: Proxmox Monitor <$MAIL_FROM>"
        echo "To: $RECIPIENT"
        echo "Subject: $SUBJECT"
        echo "MIME-Version: 1.0"
        echo "Content-Type: text/html; charset=UTF-8"
        echo ""
        echo "$HTML_BODY"
    } | msmtp --account=gmail "$RECIPIENT" >> "$LOG_FILE" 2>&1
 
    if [ $? -eq 0 ]; then
        log "[CORREO] ✓ Enviado a $RECIPIENT"
    else
        log "[CORREO] ✗ Error al enviar a $RECIPIENT — revisa $LOG_DIR/msmtp.log"
    fi
done
 
log "================================================================"
log "  FIN: Reporte completado — log en $LOG_FILE"
log "================================================================"