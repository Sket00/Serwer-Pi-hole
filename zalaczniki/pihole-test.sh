#!/usr/bin/env bash
#
# pihole-test.sh - testy funkcjonalne i pomiar czasu odpowiedzi serwera Pi-hole
#
# Użycie:  ./pihole-test.sh <adres_IP_Pi-hole> [etykieta] [liczba_powtorzen]
# Przykład: ./pihole-test.sh 192.168.100.11 docker 20
#
# Wymagania: bash >= 4, dig (pakiet bind9-dnsutils / dnsutils), awk.
# Przed uruchomieniem na serwerze Pi-hole należy dodać domenę testową
# do listy blokowanych:  pihole deny blokada-test.krt.lab
# Pomiar "zimnego" cache ma sens tylko po restarcie usługi pihole-FTL.

set -euo pipefail
export LC_ALL=C

SERVER="${1:-}"
LABEL="${2:-pihole}"
REPEAT="${3:-20}"

if [[ -z "$SERVER" ]]; then
    echo "Uzycie: $0 <adres_IP_Pi-hole> [etykieta] [liczba_powtorzen]" >&2
    exit 1
fi
command -v dig >/dev/null 2>&1 || { echo "Brak programu dig" >&2; exit 2; }

# Domeny, które powinny zostać rozwiązane poprawnie
ALLOWED=(agh.edu.pl wikipedia.org github.com debian.org kernel.org
         openwrt.org proxmox.com docker.com mozilla.org python.org)

# Domeny z domyślnej listy StevenBlack i domena dodana ręcznie (pihole deny)
BLOCKED=(ad.doubleclick.net pagead2.googlesyndication.com
         googleads.g.doubleclick.net www.googleadservices.com
         blokada-test.krt.lab)

# Jedno zapytanie typu A; wynik: "<status> <pierwszy_adres|-> <czas_ms>"
query() {
    local out status addr qtime
    out=$(dig @"$SERVER" +time=2 +tries=1 +noall +comments +answer +stats \
              "$1" A 2>/dev/null) || true
    status=$(awk -F'status: ' '/status:/ {split($2, a, ","); print a[1]; exit}' \
             <<<"$out")
    addr=$(awk '$4 == "A" {print $5; exit}' <<<"$out")
    qtime=$(awk '/Query time:/ {print $4; exit}' <<<"$out")
    echo "${status:-TIMEOUT} ${addr:--} ${qtime:--}"
}

is_blocked() {   # $1 = status, $2 = adres
    [[ "$2" == "0.0.0.0" || "$1" == "NXDOMAIN" ]] && return 0
    [[ "$1" == "NOERROR" && "$2" == "-" ]]
}

stats() {        # min/średnia/max z listy liczb podanych na stdin
    awk 'NR == 1 {min = max = $1}
         {s += $1; if ($1 < min) min = $1; if ($1 > max) max = $1}
         END {if (NR) printf "%6d %8.1f %6d %6d", min, s / NR, max, NR}'
}

NOW=$(date '+%Y-%m-%d %H:%M:%S')
printf '=== Test Pi-hole: %s (%s), %s ===\n\n' "$LABEL" "$SERVER" "$NOW"

# T1 - rozwiązywanie domen dozwolonych, pierwsze zapytanie (zimny cache)
echo "[T1] Rozwiazywanie domen dozwolonych (pierwsze zapytanie)"
t1_ok=0; cold=()
for d in "${ALLOWED[@]}"; do
    read -r st ad qt < <(query "$d")
    if [[ "$st" == "NOERROR" && "$ad" != "-" && "$ad" != "0.0.0.0" ]]; then
        res="OK"; t1_ok=$((t1_ok + 1)); cold+=("$qt")
    else
        res="BLAD"
    fi
    printf '  %-32s %-5s %-9s %-16s %5s ms\n' "$d" "$res" "$st" "$ad" "$qt"
done
printf '  Wynik: %d/%d\n\n' "$t1_ok" "${#ALLOWED[@]}"

# T2 - blokowanie domen reklamowych i domeny testowej
echo "[T2] Blokowanie domen"
t2_ok=0; blk=()
for d in "${BLOCKED[@]}"; do
    read -r st ad qt < <(query "$d")
    if is_blocked "$st" "$ad"; then
        res="BLOK"; t2_ok=$((t2_ok + 1)); blk+=("$qt")
    else
        res="PRZEP"
    fi
    printf '  %-32s %-5s %-9s %-16s %5s ms\n' "$d" "$res" "$st" "$ad" "$qt"
done
printf '  Wynik: %d/%d\n\n' "$t2_ok" "${#BLOCKED[@]}"

# T3 - czas odpowiedzi: zimny cache, ciepły cache, domeny blokowane
echo "[T3] Czas odpowiedzi [ms]"
warm=()
for _ in $(seq 1 "$REPEAT"); do
    for d in "${ALLOWED[@]}"; do
        read -r _ _ qt < <(query "$d")
        [[ "$qt" =~ ^[0-9]+$ ]] && warm+=("$qt")
    done
done
printf '  %-28s %6s %8s %6s %6s\n' "rodzaj zapytania" "min" "srednia" "max" "n"
printf '  %-28s %s\n' "zimny cache"       "$(printf '%s\n' "${cold[@]:-0}" | stats)"
printf '  %-28s %s\n' "cieply cache"      "$(printf '%s\n' "${warm[@]:-0}" | stats)"
printf '  %-28s %s\n' "domena blokowana"  "$(printf '%s\n' "${blk[@]:-0}"  | stats)"
echo

echo "=== Koniec testu: T1 ${t1_ok}/${#ALLOWED[@]}, T2 ${t2_ok}/${#BLOCKED[@]} ==="
