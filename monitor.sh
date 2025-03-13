#!/bin/bash

# wartości podstawowe
CPU_LEVEL=90
NETWORK=false
SILENT=true
LOGS=false
NO_DISK=false
GREEN_THRESHOLD=50
ORANGE_THRESHOLD=80
GREEN="\033[32m"
ORANGE="\033[33m"
RED="\033[31m"
SLEEP_TIME=5
ALERT_INTERVAL=180 # 3 minuty
LAST_ALERT_TIME=0
LOG_INTERVAL=60 # 1 minuta
BOLD="\033[1m"
UNDERLINE="\033[4m"
RESET="\033[0m"
BACKGROUND="\033[47m\033[30m"

clear
echo -ne "\033[?25l" #schowanie kursora

show_cursor_on_exit() {
    echo -ne "\033[?25h"
    exit
}
trap show_cursor_on_exit EXIT #przy wyjsciu programu wlaczamy kursor

#email regex => na poczatku litery, cyfry lub znaki specjalne @ domena (np. gmail.com albo student.pg.edu.pl), $-koniec
EMAIL_REGEX="^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"
#poziom alertow cpu => na poczatku liczba od 1 do 99, druga cyfra opcjonalna LUB (|) 100
THRESHOLD_REGEX="^[1-9][0-9]?$|^100$"

#-h lub --help
usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -n               Enable network monitoring"
    echo "  -s               Silent mode. Do not send alerts"
    echo "  -log             Enable logging to file"
    echo "  --mail EMAIL     Set the email address for alerts"
    echo "  --alert LEVEL    Set the CPU usage threshold for alerts (0-100)"
    echo "  --nodisk         Disable disk usage monitoring"
    echo "  -h, --help       Show this help message and exit"
    echo "For more information, see the man page: man bigScript"
}

# obsluga argumentow
while [[ "$#" -gt 0 ]]; do
    case $1 in
    -n) NETWORK=true ;;
    -s) SILENT=true ;;
    -log) LOGS=true ;;
    --mail)
        EMAIL="$2"
        # =~ => pattern match operator
        if [[ ! $EMAIL =~ $EMAIL_REGEX ]]; then
            echo "Invalid email address: $EMAIL"
            exit 1
        fi
        shift
        ;;
    --alert)
        CPU_LEVEL=$2
        if [[ ! $CPU_LEVEL =~ $THRESHOLD_REGEX ]]; then
            echo "Invalid CPU alert threshold: $CPU_LEVEL"
            exit 1
        fi
        shift
        ;;
    --nodisk) NO_DISK=true ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        echo -e "Unknown argument: $1 \nTry '$0 --help'"
        exit 1
        ;;
    esac
    shift
done

send_alert() {
    if [ "$SILENT" = false ]; then
        local message=$1
        local email=$EMAIL
        local subject="CPU Usage Alert"
        local smtp_server="smtp.gmail.com" #publiczny serwer smtp gmail
        local smtp_port=587
        local from=""
        local password="" # app-pasword z gmaila
        
        clear
        {
            clear
            echo "HELO localhost" #start sesji SMTP
            sleep 1
            echo "STARTTLS" #inicjalizacja polaczenia TLS
            sleep 1
            echo "AUTH LOGIN" #rozpoaczecie logowania
            sleep 1
            echo -n "$from" | base64 #kodowanie loginu w base64
            sleep 1
            echo -n "$password" | base64 #kodowanie hasla w base64
            sleep 1
            echo "MAIL FROM:<$from>" #mail nadawcy
            sleep 1
            echo "RCPT TO:<$email>" #mail odbiorcy
            sleep 1
            echo "DATA" #start sekcji danych wiadomosci
            sleep 1
            echo "Subject: $subject"
            echo "To: $email"
            echo
            echo "$message"
            echo "." #koniec sekcji danych
            sleep 1
            echo "QUIT" #koniec sesji SMTP  
        } | openssl s_client -starttls smtp -connect $smtp_server:$smtp_port -crlf -quiet
        #crlf => uzywanie dwoch znakow do oznaczenia końca linii, wiele serwerów smtp tego wymaga
        #quiet => mniej informacji wyświetlanych przez komendę
        LOG_TIMER=$((LOG_TIMER + 8))
    fi
}

network() {
    if [ "$NETWORK" = true ]; then
        #nazwa interfejsu siecowego
        local name=$(ifconfig | grep -m 1 "flags=" | awk -F: '{print $1}')
        #grep -m 1 => wynik ograniczony do pierwszego pasującego wiersza
        #awk -F: ... -> dwukropek jest separatorem, wypisz pierwsze pole

        #zapisanie pobierania/wysyłania
        local rx0=$(cat /sys/class/net/$name/statistics/rx_bytes)
        local tx0=$(cat /sys/class/net/$name/statistics/tx_bytes)

        sleep 1

        #zapisanie pobierania/wysyłania po odczekaniu sekundy
        local rx1=$(cat /sys/class/net/$name/statistics/rx_bytes)
        local tx1=$(cat /sys/class/net/$name/statistics/tx_bytes)

        local RX_OUT=$((($rx1 - $rx0)))
        local TX_OUT=$((($tx1 - $tx0)))

        NETWORK_LOG_DATA="Network: down = $RX_OUT, upl = $TX_OUT"
        NETWORK_OUT="${BOLD}Network usage${RESET}\nDownload: ${UNDERLINE}$RX_OUT${RESET} [Bps]\nUpload: ${UNDERLINE}$TX_OUT${RESET} [Bps]"
    fi
}

ram() {
    #free -m => informacje o pamięci w MB
    #grep ... => wiersz rozpoczyna się od 'Mem:'
    #awk ... => wypisanie drugiego/trzeciego pola
    local total=$(free -m | grep '^Mem:' | awk '{print $2}')
    local used=$(free -m | grep '^Mem:' | awk '{print $3}')
    local usage=$((($used * 100) / $total))

    #przypisanie kolorów do zużycia
    if [ "$usage" -lt $GREEN_THRESHOLD ]; then
        color=$GREEN
    elif [ "$usage" -lt $ORANGE_THRESHOLD ]; then
        color=$ORANGE
    else
        color=$RED
    fi

    #cofnięcie koloru do podstawowego
    RAM_LOG_DATA="RAM: $usage% ($used MB)"
    RAM_OUT="${BOLD}RAM Usage:${RESET} ${color}${UNDERLINE}${usage}%${RESET} ($used MB)"
}

cpu() {
    #top -bn1 => n1 - liczba iteracji, b - batch, bez mozliwosci interakcji
    #grep ... => wiersz rozpoczyna się od ...
    #awk ... => wypisanie 2 oraz 4 pola
    local usage=$(top -bn1 | grep "^%Cpu(s):" | awk '{print $2 + $4}')
    #zamiana float na int
    usage=$(printf "%.0f" "$usage")

    #data w formacie string (ilosc sekund od 01.01.1970)
    current_time=$(date +%s)
    time_diff=$((current_time - LAST_ALERT_TIME))

    if [ "$usage" -gt $CPU_LEVEL ] && [ "$time_diff" -ge $ALERT_INTERVAL ]; then
        send_alert "CPU usage exceeded the threshold (currently at $usage%)"
        LAST_ALERT_TIME=$current_time
    fi

    if [ "$usage" -lt $GREEN_THRESHOLD ]; then
        color=$GREEN
    elif [ "$usage" -lt $ORANGE_THRESHOLD ]; then
        color=$ORANGE
    else
        color=$RED
    fi
    CPU_LOG_DATA="CPU: $usage%"
    CPU_OUT="${BOLD}CPU Usage:${RESET} ${UNDERLINE}${color}${usage}%${RESET}"
}

uptime_f() {
    #uptime -p => pretty (np. up 5 hours, 48 minutes)
    #awk ... => $1=""; usuwa pierwsze słowo('up'), wypisuje resztę wiersza
    local time=$(uptime -p | awk '{$1=""; print $0}')
    UPTIME_OUT="System uptime:$time"
}

processes() {
    #ps aux => wyświetla wszystkie aktualne procesy, sortowanie po zużyciu CPU oraz pamięci RAM
    #head -n 4 => wyświetla pierwsze 4 wiersze
    #awk ... => NR>1 numer wiersza większy od 1 (2,3,4), wypisuje użytkownika, nazwę procesu oraz jego zużycie CPU
    local processes=$(ps aux --sort=-%cpu,-%mem | head -n 4 | awk 'NR>1{print $1, $11, $3}')

    # szerokosc terminala
    local term_width=$(tput cols)+4

    # szerokosci poszczegolnych kolumn
    local user_width=10
    local cpu_width=5
    local process_width=$((term_width - user_width - cpu_width - 6))

    #np. %-10s => string o przewidywanej maksymalnej dlugosci 10
    PROCESSES_OUT="${BOLD}Top 3 processes by CPU usage:${RESET}\n"
    PROCESSES_OUT+="$(printf "%-${user_width}s %-$((${process_width} > 0 ? process_width : 1))s %-${cpu_width}s\n" "USER" "PROCESS" "CPU")"
    PROCESSES_LOG_DATA="Top 3 processes: \n$processes"
    # formatowanie
    while IFS= read -r line; do
        local user=$(echo $line | awk '{print $1}')
        local process=$(echo $line | awk '{print $2}')
        local cpu=$(echo $line | awk '{print $3}')
        PROCESSES_OUT+="$(printf "%-${user_width}s %-$((${process_width} > 0 ? process_width : 1))s %-${cpu_width}s\n" "$user" "$process" "$cpu")"
    done <<<"$processes"
}

log_data() {
    local date_s=$(date +'%d_%m_%Y')
    local log_file="MONITOR_${date_s}.log"

    {
        echo "$(date +'%H:%M:%S')"
        echo
        echo "$UPTIME_OUT"
        echo "$CPU_LOG_DATA"
        echo "$RAM_LOG_DATA"
        if [ "$NETWORK" = true ]; then
            echo "$NETWORK_LOG_DATA"
        fi
        if [ "$NO_DISK" = false ]; then
            echo "$DISK_LOG_DATA"
        fi
        echo
        echo -e "$PROCESSES_LOG_DATA"
        echo
    } >>"$log_file"
}

disk() {
    if [ "$NO_DISK" = false ]; then
        #df -h / => info. o zużyciu pamięci dysku, na którym się znajduje katalog główny /
        #awk ... => drugi wiersz, 5 pole
        local disk_usage=$(df -h / | awk 'NR==2{print $5}')
        DISK_LOG_DATA="Disk usage: $disk_usage"
        DISK_OUT="Disk usage: ${UNDERLINE}$disk_usage${RESET}"
    fi
}

ALERT_TIMER=0
LOG_TIMER=0

center_text() {
    local term_width=$(tput cols)
    local text="$1"
    local text_length=${#text}
    local padding=$(((term_width - text_length) / 2))
    printf "%*s%s%*s\n" $padding "" "$text" $padding ""
    echo -e "$RESET"
}

# Main loop
while true; do
    ram
    cpu
    uptime_f
    processes
    network
    disk

    clear

    echo -e "${BACKGROUND}${BOLD}"
    center_text "SYSTEM MONITORING"
    echo -e "$UPTIME_OUT"
    echo
    echo -e "$CPU_OUT"
    echo -e "$RAM_OUT"
    echo
    if [ "$NETWORK" = true ]; then
        echo -e "$NETWORK_OUT"
    fi

    if [ "$NO_DISK" = false ]; then
        echo
        echo -e "$DISK_OUT"
    fi
    echo
    echo -e "$PROCESSES_OUT"

    LOG_TIMER=$((LOG_TIMER + SLEEP_TIME))

    if $LOGS && [ "$LOG_TIMER" -ge $LOG_INTERVAL ]; then
        echo "Logging data..."
        log_data
        LOG_TIMER=0
    fi

    echo -e "${BACKGROUND}${BOLD}"
    center_text "Autor: Mikołaj Wiszniewski 197925"

    sleep $SLEEP_TIME
done
