#!/bin/sh
#
# openwrt-pihole.sh - instalacja Dockera i uruchomienie Pi-hole na routerze OpenWrt
#
# Użycie:   PIHOLE_PASSWORD='haslo' ./openwrt-pihole.sh
# Wymagania: OpenWrt 25.12 lub nowszy (menedżer pakietów apk), dostęp do
#            internetu, ok. 500 MB wolnego miejsca na Dockera i obraz Pi-hole.
#
# Pi-hole działa w sieci hosta. Porty 53 i 80 routera zajmują dnsmasq i LuCI,
# dlatego Pi-hole nasłuchuje DNS na porcie 5353, a panel WWW na porcie 8080.
# Dnsmasq routera nadal obsługuje DHCP i DNS dla klientów, a zapytania
# przekazuje do Pi-hole razem z adresem klienta (EDNS0 Client Subnet).

set -eu

PIHOLE_DIR=/opt/pihole
PIHOLE_DNS_PORT=5353          # port 5353 koliduje z mDNS, jeśli działa umdns
PIHOLE_WEB_PORT=8080
PIHOLE_PASSWORD="${PIHOLE_PASSWORD:-changeme}"
UPSTREAMS="1.1.1.1;9.9.9.9"

log() { printf '[openwrt-pihole] %s\n' "$*"; }

# Czeka do 2*$2 sekund, aż polecenie $1 zakończy się powodzeniem
wait_for() {
    n=0
    until sh -c "$1" >/dev/null 2>&1; do
        n=$((n + 1))
        if [ "$n" -gt "$2" ]; then
            log "Przekroczono czas oczekiwania: $1"
            exit 1
        fi
        sleep 2
    done
}

# 1. Instalacja Dockera z repozytorium OpenWrt
log "Instalacja pakietow Docker"
apk update
apk add dockerd docker docker-compose

# 2. Uruchomienie usługi dockerd, także przy starcie systemu
log "Uruchamianie dockerd"
/etc/init.d/dockerd enable
/etc/init.d/dockerd start
wait_for "docker info" 30

# 3. Plik compose.yaml
log "Tworzenie $PIHOLE_DIR/compose.yaml"
mkdir -p "$PIHOLE_DIR"
cd "$PIHOLE_DIR"
cat > compose.yaml <<EOF
services:
  pihole:
    image: pihole/pihole:latest
    container_name: pihole
    network_mode: host
    environment:
      TZ: Europe/Warsaw
      FTLCONF_webserver_api_password: "$PIHOLE_PASSWORD"
      FTLCONF_dns_port: "$PIHOLE_DNS_PORT"
      FTLCONF_webserver_port: "$PIHOLE_WEB_PORT"
      FTLCONF_dns_upstreams: "$UPSTREAMS"
      FTLCONF_dns_listeningMode: "all"
    volumes:
      - ./etc-pihole:/etc/pihole
    restart: unless-stopped
EOF

# 4. Uruchomienie kontenera; konfiguracja dnsmasq zmienia się dopiero,
#    gdy Pi-hole odpowiada, aby nie przerwać działania DNS w sieci
log "Uruchamianie kontenera pihole"
docker-compose up -d
wait_for "[ \"\$(docker inspect -f '{{.State.Health.Status}}' pihole)\" = healthy ]" 60

# 5. Dnsmasq: wszystkie zapytania klientów do Pi-hole
log "Konfiguracja dnsmasq"
uci set dhcp.@dnsmasq[0].noresolv='1'
uci -q del_list dhcp.@dnsmasq[0].server="127.0.0.1#$PIHOLE_DNS_PORT" || true
uci add_list dhcp.@dnsmasq[0].server="127.0.0.1#$PIHOLE_DNS_PORT"
uci set dhcp.@dnsmasq[0].addsubnet='32,128'   # adres klienta w EDNS0 (ECS)
uci set dhcp.@dnsmasq[0].cachesize='0'        # każde zapytanie trafia do Pi-hole
uci set dhcp.@dnsmasq[0].rebind_localhost='1' # przepuszcza odpowiedź 0.0.0.0
uci commit dhcp
/etc/init.d/dnsmasq restart

log "Gotowe. Panel: http://<adres_routera>:$PIHOLE_WEB_PORT/admin"
