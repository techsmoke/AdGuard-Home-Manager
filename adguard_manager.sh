#!/bin/bash

SCRIPT_VERSION="v1.0"

ADGUARD_DIR="/opt/AdGuardHome"
BACKUP_DIR="/mnt/adguard-backup"
INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh"
DEFAULT_WEB_INTERFACE_PORT=3000
DEFAULT_HTTPS_PORT=443

ensure_dependencies() {
    for cmd in wget curl tar systemctl; do
        if ! command -v $cmd >/dev/null; then
            echo "$cmd wird benötigt! Bitte installieren."
            exit 1
        fi
    done
    sudo mkdir -p "$BACKUP_DIR"
}

get_adguard_http_port() {
    [[ -f "$ADGUARD_DIR/AdGuardHome.yaml" ]]         && grep 'address:' "$ADGUARD_DIR/AdGuardHome.yaml" | grep -oP ':\K[0-9]+'         || echo "$DEFAULT_WEB_INTERFACE_PORT"
}

get_adguard_https_port() {
    [[ -f "$ADGUARD_DIR/AdGuardHome.yaml" ]]         && grep 'port_https:' "$ADGUARD_DIR/AdGuardHome.yaml" | awk '{print $2}'         || echo "$DEFAULT_HTTPS_PORT"
}

check_ports() {
    for PORT in 53 80 443 $DEFAULT_WEB_INTERFACE_PORT; do
        if lsof -i :$PORT >/dev/null; then
            read -p "⚠️  Port $PORT ist belegt. Alternativen Port angeben: " newport
            PORT=$newport
        fi
    done
}

install_adguard() {
    [[ -d "$ADGUARD_DIR" ]] && echo "✅ AdGuard ist bereits installiert." && return
    check_ports
    echo "⬇️  Installiere AdGuard Home..."
    wget --no-verbose -O - "$INSTALL_SCRIPT_URL" | sh -s -- -v
    SERVER_IP=$(hostname -I | awk '{print $1}')
    PORT=$(get_adguard_https_port)
    echo -e "\n\033[1;32m✅ AdGuard Home ist jetzt installiert!\033[0m"
    echo -e "\033[1;36m🌐 Verwaltung erreichbar unter: https://$SERVER_IP:$PORT\033[0m"
}

update_adguard() {
    [[ ! -d "$ADGUARD_DIR" ]] && echo "❌ AdGuard ist nicht installiert." && return
    echo "🔄 Aktualisiere AdGuard Home..."
    wget --no-verbose -O - "$INSTALL_SCRIPT_URL" | sh -s -- -v -r
}

uninstall_adguard() {
    [[ ! -f "$ADGUARD_DIR/AdGuardHome" ]] && echo -e "\033[1;31m❌ AdGuard ist nicht installiert.\033[0m" && read -p "Drücke ENTER..." _ && return
    sudo "$ADGUARD_DIR/AdGuardHome" -s stop
    sudo "$ADGUARD_DIR/AdGuardHome" -s uninstall
    sudo rm -rf "$ADGUARD_DIR"
    echo -e "\033[1;32m✅ AdGuard wurde entfernt.\033[0m"
    read -p "Drücke ENTER..." _
}

status_adguard() {
    if pgrep -x "AdGuardHome" >/dev/null; then
        echo -e "\033[1;32m✅ AdGuard Home läuft\033[0m"
    else
        echo -e "\033[1;31m❌ AdGuard Home ist gestoppt\033[0m"
    fi
    read -p "Drücke ENTER..." _
}

create_backup() {
    timestamp=$(date +'%d-%m-%Y_%H-%M')
    filename="backup_${timestamp}.tar.gz"
    tar -czf "$BACKUP_DIR/$filename" "$ADGUARD_DIR"
    echo "✅ Backup gespeichert: $filename"
    backups=($(ls -1t "$BACKUP_DIR"/backup_*.tar.gz))
    if (( ${#backups[@]} > 3 )); then
        for ((i=3; i<${#backups[@]}; i++)); do
            rm -f "${backups[$i]}"
            echo "🗑️  Altes Backup gelöscht: ${backups[$i]}"
        done
    fi
}

restore_backup() {
    echo "🔁 Backup-Wiederherstellung..."
    select f in $(ls -1t "$BACKUP_DIR"/backup_*.tar.gz 2>/dev/null); do
        if [[ -n "$f" ]]; then
            sudo "$ADGUARD_DIR/AdGuardHome" -s stop
            sudo rm -rf "$ADGUARD_DIR"
            tar -xzf "$f" -C /
            echo "✅ Wiederhergestellt: $f"
            read -p "Drücke ENTER..." _
            return
        else
            echo "❌ Kein Backup ausgewählt."
            return
        fi
    done
}

install_apache_certbot() {
    echo "🌐 Apache & Certbot Setup..."
    ! dpkg -l | grep -q apache2 && sudo apt update && sudo apt install -y apache2
    read -p "🌍 Domain eingeben: " DOMAIN
    CONF_PATH="/etc/apache2/sites-available/$DOMAIN.conf"
    HTTP_PORT=$(get_adguard_http_port)
    HTTPS_PORT=$(get_adguard_https_port)

    sudo bash -c "cat > $CONF_PATH" <<EOF
<VirtualHost *:80>
    ServerName $DOMAIN
    ProxyPreserveHost On
    ProxyPass / http://127.0.0.1:$HTTP_PORT/
    ProxyPassReverse / http://127.0.0.1:$HTTP_PORT/
</VirtualHost>
EOF

    sudo a2enmod proxy proxy_http proxy_ssl ssl headers
    sudo a2ensite "$DOMAIN"
    sudo systemctl reload apache2

    echo "🔐 Erstelle Zertifikat..."
    sudo certbot --apache -d "$DOMAIN"

    SSL_CONF="/etc/apache2/sites-available/${DOMAIN}-le-ssl.conf"
    for i in {1..5}; do [[ -f "$SSL_CONF" ]] && break; sleep 1; done

    if [[ -f "$SSL_CONF" ]]; then
        sudo bash -c "cat > $SSL_CONF" <<EOF
<IfModule mod_ssl.c>
<VirtualHost *:443>
    ServerName $DOMAIN
    ProxyPreserveHost On
    SSLProxyEngine On
    ProxyPass / https://127.0.0.1:$HTTPS_PORT/
    ProxyPassReverse / https://127.0.0.1:$HTTPS_PORT/
    Include /etc/letsencrypt/options-ssl-apache.conf
    SSLCertificateFile /etc/letsencrypt/live/$DOMAIN/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/$DOMAIN/privkey.pem
</VirtualHost>
</IfModule>
EOF
        sudo systemctl reload apache2
        echo "✅ SSL-Konfiguration aktualisiert!"
    else
        echo "❌ SSL-Konfiguration wurde nicht erstellt!"
    fi
}

renew_certificates() {
    echo "🔁 Erneuere Zertifikate..."
    sudo certbot renew
    echo "✅ Zertifikate erneuert."
    read -p "Drücke ENTER..." _
}

show_ip_info() {
    SERVER_IP=$(hostname -I | awk '{print $1}')
    HTTP_PORT=$(get_adguard_http_port)
    HTTPS_PORT=$(get_adguard_https_port)

    echo -e "\n📡 \033[1;36mIP-Adresse:\033[0m $SERVER_IP"
    echo -e "🛡️  AdGuard Home URL (HTTP):  (\033[1;36mhttp://$SERVER_IP:$HTTP_PORT\033[0m)"
    echo -e "🛡️  AdGuard Home URL (HTTPS): (\033[1;36mhttps://$SERVER_IP:$HTTPS_PORT\033[0m)"

    DOMAIN_FILE=$(find /etc/apache2/sites-available/ -name "*.conf" -exec grep -l "ProxyPass" {} + 2>/dev/null | head -n1)
    if [[ -n "$DOMAIN_FILE" ]]; then
        DOMAIN=$(grep "ServerName" "$DOMAIN_FILE" | awk '{print $2}')
        if [[ -n "$DOMAIN" ]]; then
            echo -e "🛡️  Domain (HTTP):  (\033[1;36mhttp://$DOMAIN:$HTTP_PORT\033[0m)"
            echo -e "🛡️  Domain (HTTPS): (\033[1;36mhttps://$DOMAIN:$HTTPS_PORT\033[0m)"
        fi
    fi

    echo ""
    read -p "Drücke ENTER..." _
}

menu() {
    while true; do
        echo ""
        echo "╔════════════════════════════════════════════════════════╗"
        echo "║   🌐 AdGuard Manager Menü ~TechSmoke (${SCRIPT_VERSION})            ║"
        echo "╚════════════════════════════════════════════════════════╝"
        echo " 1) 🚀 AdGuard installieren"
        echo " 2) 🔄 AdGuard aktualisieren"
        echo " 3) 🌐 Apache & Certbot einrichten"
        echo " 4) 🔁 Zertifikate erneuern"
        echo " 5) 📦 Backup erstellen"
        echo " 6) ♻️  Backup wiederherstellen"
        echo " 7) ▶️  AdGuard starten"
        echo " 8) ⏹️  AdGuard stoppen"
        echo " 9) 📊 Status anzeigen"
        echo "10) 🌍 IP & URLs anzeigen"
        echo "11) 🗑️  AdGuard deinstallieren"
        echo "12) 🚪 Beenden"
        read -rp "Option: " CHOICE

        case "$CHOICE" in
            1) install_adguard ;;
            2) update_adguard ;;
            3) install_apache_certbot ;;
            4) renew_certificates ;;
            5) create_backup ;;
            6) restore_backup ;;
            7) sudo "$ADGUARD_DIR/AdGuardHome" -s start ;;
            8) sudo "$ADGUARD_DIR/AdGuardHome" -s stop ;;
            9) status_adguard ;;
            10) show_ip_info ;;
            11) uninstall_adguard ;;
            12) echo "👋 Auf Wiedersehen!"; break ;;
            *) echo "❗ Ungültige Eingabe." ;;
        esac
    done
}

# Start
ensure_dependencies
menu
