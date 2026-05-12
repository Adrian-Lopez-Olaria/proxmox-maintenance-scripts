<div align="center">

# 🖥️ Proxmox VE — Maintenance Scripts

**Scripts de mantenimiento automatizado para nodos Proxmox VE**  
Pensados para implantarse en entornos de clientes. Toda la configuración está agrupada al inicio de cada archivo para facilitar su adaptación.

![Bash](https://img.shields.io/badge/Bash-4EAA25?style=flat&logo=gnubash&logoColor=white)
![Proxmox](https://img.shields.io/badge/Proxmox_VE-E57000?style=flat&logo=proxmox&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-blue?style=flat)

</div>

---

## 📁 Estructura del repositorio

```
proxmox-maintenance-scripts/
├── scripts/
│   ├── pve-cleanup.sh       # Limpieza del sistema
│   ├── pve-update.sh        # Actualización segura con backup previo
│   └── pve-report.sh        # Reporte diario por correo HTML
├── assets/
│   ├── CAPTURA1.png
│   ├── CAPTURA2.png
│   └── CAPTURA3.png
└── README.md
```

---

## 📋 Scripts disponibles

| Script | Descripción | Frecuencia recomendada |
|--------|-------------|----------------------|
| [`pve-cleanup.sh`](scripts/pve-cleanup.sh) | Limpieza de logs, backups y paquetes | Mensual |
| [`pve-update.sh`](scripts/pve-update.sh) | Actualización segura con backup previo | Semanal |
| [`pve-report.sh`](scripts/pve-report.sh) | Reporte de estado por correo HTML | Diario |

---

## 🧹 pve-cleanup.sh — Limpieza del sistema

Limpia el espacio acumulado en el nodo: journal del sistema, logs generales, backups antiguos y paquetes residuales de apt. Detecta automáticamente el tipo de storage (ZFS, LVM o Directory) y actúa en consecuencia.

**Variables a configurar:**
```bash
BACKUP_DIR="/var/lib/vz/dump"   # Ruta de los backups en este cliente
BACKUP_RETENTION_DAYS=60        # Días que se conservan los backups
JOURNAL_MAX_SIZE="500M"         # Tamaño máximo del journal
DISK_WARN_PERCENT=85            # % de disco que activa la alerta en el log
```

**Cron recomendado** — primer día de cada mes a las 04:00:
```
0 4 1 * * /usr/local/bin/pve-cleanup.sh
```

Ejecución real mostrando la detección de storages, limpieza del journal y resumen de espacio liberado:

![Ejecución de pve-cleanup.sh](assets/CAPTURA2.png)

---

## 🔄 pve-update.sh — Actualización segura

Antes de tocar nada, realiza un backup completo de todas las VMs y contenedores en el storage externo configurado. Si algún backup falla, el script se detiene y no actualiza. Si todo va bien, aplica `apt upgrade` y limpia paquetes huérfanos.

Si se ejecuta **manualmente** y el sistema necesita reinicio, pregunta si reiniciar ahora o más tarde. Si corre por **cron**, solo lo anota en el log.

**Variables a configurar:**
```bash
BACKUP_STORAGE="nombre-storage-externo"  # Nombre del storage (ver: pvesm status)
BACKUP_COMPRESS="zstd"                   # Compresión: zstd | lzo | gzip
```

**Cron recomendado** — domingos a las 03:00:
```
0 3 * * 0 /usr/local/bin/pve-update.sh
```

---

## 📧 pve-report.sh — Reporte diario por correo

Envía cada día un correo HTML con el estado del nodo: uso de CPU, RAM y disco con barras de progreso en verde, naranja o rojo según los umbrales configurados. Incluye también el número de VMs y contenedores activos y los paquetes pendientes de actualización.

> Requiere `msmtp` instalado: `apt-get install -y msmtp msmtp-mta`  
> Para Gmail es necesaria una **contraseña de aplicación**: https://myaccount.google.com/apppasswords

**Variables a configurar:**
```bash
SMTP_USER="tu-cuenta@gmail.com"
SMTP_PASS="xxxx xxxx xxxx xxxx"   # Contraseña de aplicación (16 caracteres)
MAIL_TO="usuario1@empresa.com usuario2@empresa.com"
WARN_PERCENT=85                   # Umbral para resaltar en rojo
```

**Cron recomendado** — todos los días a las 11:00:
```
0 11 * * * /usr/local/bin/pve-report.sh
```

Ejecución real con envío de correo a las cuentas configuradas:

![Ejecución de pve-report.sh](assets/CAPTURA1.png)

---

## ⏱️ Cron configurado

Una vez instalados los scripts, el crontab queda así:

![Crontab configurado](assets/CAPTURA3.png)

---

## 🚀 Instalación rápida

```bash
# 1. Copiar los scripts al nodo
scp scripts/pve-cleanup.sh scripts/pve-update.sh scripts/pve-report.sh \
    root@IP-DEL-NODO:/usr/local/bin/

# 2. Dar permisos de ejecución
chmod +x /usr/local/bin/pve-cleanup.sh
chmod +x /usr/local/bin/pve-update.sh
chmod +x /usr/local/bin/pve-report.sh

# 3. Instalar msmtp
apt-get install -y msmtp msmtp-mta

# 4. Probar manualmente antes de activar el cron
bash /usr/local/bin/pve-report.sh
bash /usr/local/bin/pve-cleanup.sh
bash /usr/local/bin/pve-update.sh

# 5. Configurar el cron
crontab -e
```

> Los logs se guardan en `/var/log/pve-maintenance/` con fecha en el nombre de cada archivo.

---

<div align="center">
  <sub>Desarrollado por Adrián López Olaria</sub>
</div>
