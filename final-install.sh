#!/bin/bash
# Clean minimal version to avoid quote parsing errors

CYAN=$(tput setaf 6)
GREEN=$(tput setaf 2)
RED=$(tput setaf 1)
YELLOW=$(tput setaf 3)
RESET=$(tput sgr0)
CONF=/etc/1plus-gre.conf
TUN=1plus-m2
WATCHDOG_SERVICE=1plus-gre-watchdog.service
TUNNEL_SERVICE=1plus-gre-tunnel.service
AUTO_RESTART_SERVICE=1plus-gre-auto-restart.service
AUTO_RESTART_TIMER=1plus-gre-auto-restart.timer
STATE_FILE="/var/run/1plus-gre.state"

# Save terminal settings
SAVED_STTY=$(stty -g 2>/dev/null)

# Restore terminal on exit
cleanup() {
    if [ -n "$SAVED_STTY" ]; then
        stty "$SAVED_STTY" 2>/dev/null
    fi
    echo ""
}
trap cleanup EXIT

require_root(){ [ "$EUID" -ne 0 ] && { echo "Run as root"; exit 1; }; }

get_ip(){
  for s in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
    ip=$(curl -4 -s --max-time 3 "$s" 2>/dev/null | tr -d '\n\r')
    [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && echo "$ip" && return
  done
  hostname -I | awk '{print $1}'
}

add_iran(){
 ip tunnel add $TUN mode gre local "$1" remote "$2" ttl 255 2>/dev/null
 ip link set $TUN up
 ip addr add 132.168.30.2/30 dev $TUN 2>/dev/null
 sysctl -w net.ipv4.ip_forward=1 >/dev/null
 iptables -t nat -A PREROUTING -p tcp --dport 22 -j DNAT --to-destination 132.168.30.2
 iptables -t nat -A PREROUTING -j DNAT --to-destination 132.168.30.1
 iptables -t nat -A POSTROUTING -j MASQUERADE
}

add_foreign(){
 ip tunnel add $TUN mode gre local "$1" remote "$2" ttl 255 2>/dev/null
 ip link set $TUN up
 ip addr add 132.168.30.1/30 dev $TUN 2>/dev/null
 iptables -A INPUT --proto icmp -j DROP
}

clean_all(){
 systemctl stop $WATCHDOG_SERVICE 2>/dev/null
 systemctl disable $WATCHDOG_SERVICE 2>/dev/null
 systemctl stop $TUNNEL_SERVICE 2>/dev/null
 systemctl disable $TUNNEL_SERVICE 2>/dev/null
 systemctl stop $AUTO_RESTART_TIMER 2>/dev/null
 systemctl disable $AUTO_RESTART_TIMER 2>/dev/null
 rm -f /etc/systemd/system/$WATCHDOG_SERVICE /etc/systemd/system/$TUNNEL_SERVICE
 rm -f /etc/systemd/system/$AUTO_RESTART_SERVICE /etc/systemd/system/$AUTO_RESTART_TIMER
 rm -f /usr/local/bin/1plus-gre-*
 ip link set $TUN down 2>/dev/null
 ip tunnel del $TUN 2>/dev/null
 iptables -t nat -F; iptables -F
 rm -f "$CONF" "$STATE_FILE"
 systemctl daemon-reload 2>/dev/null
 logger "1plus-gre: All configurations cleaned up"
}

coordinated_restart(){
 local role="$1"
 local local_ip="$2"
 local remote_ip="$3"
 
 date +%s > "$STATE_FILE"
 logger "1plus-gre: Performing coordinated restart (Role: $role)"
 
 ip link set $TUN down 2>/dev/null
 ip tunnel del $TUN 2>/dev/null
 iptables -t nat -F
 iptables -F
 sleep 2
 
 if [ "$role" = "IRAN" ]; then
  add_iran "$local_ip" "$remote_ip"
 else
  add_foreign "$local_ip" "$remote_ip"
 fi
 logger "1plus-gre: Coordinated restart completed"
}

create_tunnel_service(){
 # ایجاد اسکریپت راه‌اندازی تونل
 cat >/usr/local/bin/1plus-gre-setup.sh <<EOF
#!/bin/bash
source /etc/1plus-gre.conf 2>/dev/null || exit 0
if [ "\$ROLE" = "IRAN" ]; then
  ip tunnel add $TUN mode gre local "\$IP_LOCAL" remote "\$IP_REMOTE" ttl 255 2>/dev/null
  ip link set $TUN up
  ip addr add 132.168.30.2/30 dev $TUN 2>/dev/null
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  iptables -t nat -A PREROUTING -p tcp --dport 22 -j DNAT --to-destination 132.168.30.2
  iptables -t nat -A PREROUTING -j DNAT --to-destination 132.168.30.1
  iptables -t nat -A POSTROUTING -j MASQUERADE
else
  ip tunnel add $TUN mode gre local "\$IP_LOCAL" remote "\$IP_REMOTE" ttl 255 2>/dev/null
  ip link set $TUN up
  ip addr add 132.168.30.1/30 dev $TUN 2>/dev/null
  iptables -A INPUT --proto icmp -j DROP
fi
logger "1plus-gre: Tunnel setup completed"
EOF

 # ایجاد اسکریپت توقف تونل
 cat >/usr/local/bin/1plus-gre-teardown.sh <<EOF
#!/bin/bash
ip link set $TUN down 2>/dev/null
ip tunnel del $TUN 2>/dev/null
iptables -t nat -F 2>/dev/null
iptables -F 2>/dev/null
logger "1plus-gre: Tunnel teardown completed"
EOF

 chmod +x /usr/local/bin/1plus-gre-setup.sh /usr/local/bin/1plus-gre-teardown.sh

 # ایجاد سرویس systemd برای تونل
 cat >/etc/systemd/system/$TUNNEL_SERVICE <<EOF
[Unit]
Description=1plus GRE Tunnel
After=network.target
Wants=network.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/1plus-gre-setup.sh
ExecStop=/usr/local/bin/1plus-gre-teardown.sh
[Install]
WantedBy=multi-user.target
EOF

 systemctl daemon-reload
}

create_watchdog_service(){
 # ایجاد اسکریپت watchdog
 cat >/usr/local/bin/1plus-gre-watchdog.sh <<EOF
#!/bin/bash
CONF=/etc/1plus-gre.conf
TUN=1plus-m2
STATE_FILE="/var/run/1plus-gre.state"
source \$CONF 2>/dev/null || exit 0
[ "\$ROLE" = IRAN ] && TARGET=132.168.30.1 || TARGET=132.168.30.2

check_cooldown(){
 if [ -f "\$STATE_FILE" ]; then
  last_restart=\$(cat "\$STATE_FILE")
  current_time=\$(date +%s)
  if [ \$((current_time - last_restart)) -lt 60 ]; then
   return 1
  fi
 fi
 return 0
}

fail=0
consecutive_failures=0
while true; do
 if check_cooldown; then
  timeout 2 bash -c "</dev/tcp/\$TARGET/22" >/dev/null 2>&1
  if [ \$? -ne 0 ]; then
   fail=\$((fail+1))
   consecutive_failures=\$((consecutive_failures+1))
   
   if [ \$fail -ge 3 ]; then
    coordinated_restart "\$ROLE" "\$IP_LOCAL" "\$IP_REMOTE"
    fail=0
    consecutive_failures=0
    sleep 10
   fi
  else
   fail=0
   consecutive_failures=0
  fi
 fi
 sleep 15
done
EOF

 chmod +x /usr/local/bin/1plus-gre-watchdog.sh

 # ایجاد سرویس systemd برای watchdog
 cat >/etc/systemd/system/$WATCHDOG_SERVICE <<EOF
[Unit]
Description=1plus GRE Watchdog
After=1plus-gre-tunnel.service
Requires=1plus-gre-tunnel.service
[Service]
ExecStart=/usr/local/bin/1plus-gre-watchdog.sh
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

 systemctl daemon-reload
}

create_auto_restart_service(){
 local interval_hours="$1"
 
 # ایجاد اسکریپت ریستارت خودکار
 cat >/usr/local/bin/1plus-gre-auto-restart.sh <<EOF
#!/bin/bash
CONF=/etc/1plus-gre.conf
source \$CONF 2>/dev/null || exit 0

logger "1plus-gre: Starting scheduled restart (Interval: ${interval_hours} hours)"

# توقف watchdog موقت
systemctl stop $WATCHDOG_SERVICE 2>/dev/null

# ریستارت تونل
coordinated_restart "\$ROLE" "\$IP_LOCAL" "\$IP_REMOTE"

# راه‌اندازی مجدد watchdog
systemctl start $WATCHDOG_SERVICE 2>/dev/null

logger "1plus-gre: Scheduled restart completed"
EOF

 chmod +x /usr/local/bin/1plus-gre-auto-restart.sh

 # ایجاد سرویس systemd برای ریستارت خودکار
 cat >/etc/systemd/system/$AUTO_RESTART_SERVICE <<EOF
[Unit]
Description=1plus GRE Auto Restart
After=1plus-gre-tunnel.service
Requires=1plus-gre-tunnel.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/1plus-gre-auto-restart.sh
[Install]
WantedBy=multi-user.target
EOF

 # ایجاد تایمر systemd برای اجرای دوره‌ای
 cat >/etc/systemd/system/$AUTO_RESTART_TIMER <<EOF
[Unit]
Description=Auto restart 1plus GRE tunnel every ${interval_hours} hours
Requires=1plus-gre-auto-restart.service
[Timer]
OnBootSec=1h
OnUnitActiveSec=${interval_hours}h
Persistent=true
[Install]
WantedBy=timers.target
EOF

 systemctl daemon-reload
}

show_status(){
 echo -e "\n${CYAN}=== Current Status ===${RESET}"
 
 if [ -f "$CONF" ]; then
  source "$CONF" 2>/dev/null
  echo "Role: ${ROLE:-Not set}"
  echo "Local IP: ${IP_LOCAL:-Not set}"
  echo "Remote IP: ${IP_REMOTE:-Not set}"
 else
  echo "Configuration: Not installed"
 fi
 
 echo -e "\n${CYAN}Services:${RESET}"
 if systemctl is-active $TUNNEL_SERVICE >/dev/null 2>&1; then
  echo -e "Tunnel Service: ${GREEN}ACTIVE${RESET}"
 else
  echo -e "Tunnel Service: ${RED}INACTIVE${RESET}"
 fi
 
 if systemctl is-active $WATCHDOG_SERVICE >/dev/null 2>&1; then
  echo -e "Watchdog Service: ${GREEN}ACTIVE${RESET}"
 else
  echo -e "Watchdog Service: ${RED}INACTIVE${RESET}"
 fi
 
 if systemctl is-active $AUTO_RESTART_TIMER >/dev/null 2>&1; then
  timer_status=$(systemctl show -p ActiveEnterTimestamp $AUTO_RESTART_TIMER 2>/dev/null | cut -d= -f2)
  next_run=$(systemctl show -p NextElapseUSecRealtime $AUTO_RESTART_TIMER 2>/dev/null | cut -d= -f2)
  echo -e "Auto-Restart Timer: ${GREEN}ACTIVE${RESET}"
  if [ -n "$timer_status" ]; then
    echo -e "  Last run: $timer_status"
  fi
  if [ -n "$next_run" ] && [ "$next_run" != "0" ]; then
    echo -e "  Next run: $(date -d @$((${next_run::-6} / 1000000)) 2>/dev/null || echo 'Unknown')"
  fi
 else
  echo -e "Auto-Restart Timer: ${RED}INACTIVE${RESET}"
 fi
 
 echo -e "\n${CYAN}Tunnel Interface:${RESET}"
 if ip link show $TUN 2>/dev/null >/dev/null; then
  echo -e "Status: ${GREEN}UP${RESET}"
  ip addr show $TUN 2>/dev/null | grep inet | sed 's/^[ \t]*//' || true
 else
  echo -e "Status: ${RED}DOWN${RESET}"
 fi
}

# Simple menu system without complex terminal handling
simple_menu() {
    while true; do
        clear
        echo -e "${CYAN}╔══════════════════════════════════════╗${RESET}"
        echo -e "${CYAN}║       1Plus GRE Tunnel Manager       ║${RESET}"
        echo -e "${CYAN}╚══════════════════════════════════════╝${RESET}"
        
        show_status
        
        echo -e "\n${CYAN}═══════════ Main Menu ═══════════${RESET}"
        echo "1  - Install IRAN Server"
        echo "2  - Install FOREIGN Server"
        echo "3  - Reinstall Tunnel Only (no services)"
        echo "4  - Tunnel Service Management"
        echo "5  - Watchdog Service Management"
        echo "6  - Auto-Restart Management"
        echo "7  - Manual Tunnel Operations"
        echo "8  - System Operations"
        echo "9  - Exit"
        echo -n -e "\n${CYAN}Select option [1-9]: ${RESET}"
        
        # Simple read without echo control
        read -r OPTION </dev/tty
        
        case $OPTION in
            1) install_server "IRAN";;
            2) install_server "FOREIGN";;
            3) reinstall_tunnel;;
            4) manage_tunnel_service;;
            5) manage_watchdog_service;;
            6) manage_auto_restart;;
            7) manual_operations;;
            8) system_operations;;
            9) echo -e "\n${CYAN}Goodbye!${RESET}"; exit 0;;
            *) echo -e "\n${RED}Invalid option${RESET}"; sleep 1;;
        esac
    done
}

install_server() {
    local ROLE="$1"
    
    clear
    echo -e "${CYAN}══════ Install $ROLE Server ══════${RESET}"
    
    LOCAL_IP=$(get_ip)
    echo -e "\n${CYAN}Detected local IP: $LOCAL_IP${RESET}"
    
    # Get local IP
    while true; do
        echo -n "Local server IP [$LOCAL_IP]: "
        read -r USER_IP </dev/tty
        [ -n "$USER_IP" ] && LOCAL_IP="$USER_IP"
        
        if [[ $LOCAL_IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            break
        else
            echo -e "${RED}Invalid IP address format${RESET}"
        fi
    done
    
    # Get remote IP
    while true; do
        echo -n "Enter opposite server IP: "
        read -r REMOTE_IP </dev/tty
        
        if [[ $REMOTE_IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            break
        else
            echo -e "${RED}Invalid IP address format${RESET}"
        fi
    done
    
    echo -e "\n${YELLOW}Installing $ROLE server...${RESET}"
    
    # توقف سرویس‌های موجود
    systemctl stop $WATCHDOG_SERVICE 2>/dev/null
    systemctl stop $TUNNEL_SERVICE 2>/dev/null
    systemctl stop $AUTO_RESTART_TIMER 2>/dev/null
    
    # حذف تونل قدیمی
    ip link set $TUN down 2>/dev/null
    ip tunnel del $TUN 2>/dev/null
    iptables -t nat -F 2>/dev/null
    iptables -F 2>/dev/null
    
    # ایجاد تونل جدید
    if [ "$ROLE" = "IRAN" ]; then
        add_iran "$LOCAL_IP" "$REMOTE_IP"
    else
        add_foreign "$LOCAL_IP" "$REMOTE_IP"
    fi
    
    # ذخیره تنظیمات
    echo "ROLE=$ROLE" > "$CONF"
    echo "IP_LOCAL=$LOCAL_IP" >> "$CONF"
    echo "IP_REMOTE=$REMOTE_IP" >> "$CONF"
    
    # ایجاد فایل‌های سرویس
    create_tunnel_service
    create_watchdog_service
    
    echo -e "\n${GREEN}╔══════════════════════════════════════╗${RESET}"
    echo -e "${GREEN}║           INSTALLATION SUCCESS          ║${RESET}"
    echo -e "${GREEN}╚══════════════════════════════════════╝${RESET}"
    echo -e "\n${CYAN}Server Role:${RESET} $ROLE"
    echo -e "${CYAN}Local IP:${RESET} $LOCAL_IP"
    echo -e "${CYAN}Remote IP:${RESET} $REMOTE_IP"
    echo -e "\n${YELLOW}Note:${RESET} Services are created but not enabled."
    
    echo -e "\n${CYAN}Press Enter to continue...${RESET}"
    read -r </dev/tty
}

reinstall_tunnel() {
    clear
    echo -e "${CYAN}══════ Reinstall Tunnel Only ══════${RESET}"
    
    if [ ! -f "$CONF" ]; then
        echo -e "\n${RED}[ERROR] Configuration not found! Please install server first.${RESET}"
        echo -e "\n${CYAN}Press Enter to continue...${RESET}"
        read -r </dev/tty
        return
    fi
    
    source "$CONF"
    
    # حذف و ایجاد مجدد تونل
    ip link set $TUN down 2>/dev/null
    ip tunnel del $TUN 2>/dev/null
    iptables -t nat -F 2>/dev/null
    iptables -F 2>/dev/null
    
    if [ "$ROLE" = "IRAN" ]; then
        add_iran "$IP_LOCAL" "$IP_REMOTE"
    else
        add_foreign "$IP_LOCAL" "$IP_REMOTE"
    fi
    
    echo -e "\n${GREEN}[SUCCESS] Tunnel reinstalled successfully${RESET}"
    echo -e "\n${CYAN}Press Enter to continue...${RESET}"
    read -r </dev/tty
}

manage_tunnel_service() {
    while true; do
        clear
        echo -e "${CYAN}==== Tunnel Service Management ====${RESET}"
        service_status=$(systemctl is-active $TUNNEL_SERVICE 2>/dev/null || echo 'Not installed')
        echo -e "Current status: $service_status"
        echo -e "\n${CYAN}Options:${RESET}"
        echo "1 - Enable Tunnel Service (auto-start on boot)"
        echo "2 - Disable Tunnel Service"
        echo "3 - Start Tunnel Service (now)"
        echo "4 - Stop Tunnel Service (now)"
        echo "5 - Restart Tunnel Service"
        echo "6 - Back to Main Menu"
        echo -n -e "\n${CYAN}Select option [1-6]: ${RESET}"
        
        read -r OPTION </dev/tty
        
        case $OPTION in
            1)
                if [ ! -f "$CONF" ]; then
                    echo -e "\n${RED}[ERROR] Configuration not found!${RESET}"
                else
                    systemctl enable $TUNNEL_SERVICE 2>/dev/null
                    echo -e "\n${GREEN}[SUCCESS] Tunnel service enabled${RESET}"
                fi
                ;;
            2)
                systemctl disable $TUNNEL_SERVICE 2>/dev/null
                echo -e "\n${GREEN}[SUCCESS] Tunnel service disabled${RESET}"
                ;;
            3)
                systemctl start $TUNNEL_SERVICE 2>/dev/null
                echo -e "\n${GREEN}[SUCCESS] Tunnel service started${RESET}"
                ;;
            4)
                systemctl stop $TUNNEL_SERVICE 2>/dev/null
                echo -e "\n${GREEN}[SUCCESS] Tunnel service stopped${RESET}"
                ;;
            5)
                systemctl restart $TUNNEL_SERVICE 2>/dev/null
                echo -e "\n${GREEN}[SUCCESS] Tunnel service restarted${RESET}"
                ;;
            6)
                return
                ;;
            *)
                echo -e "\n${RED}Invalid option${RESET}"
                ;;
        esac
        
        echo -e "\n${CYAN}Press Enter to continue...${RESET}"
        read -r </dev/tty
    done
}

manage_watchdog_service() {
    while true; do
        clear
        echo -e "${CYAN}==== Watchdog Service Management ====${RESET}"
        service_status=$(systemctl is-active $WATCHDOG_SERVICE 2>/dev/null || echo 'Not installed')
        echo -e "Current status: $service_status"
        echo -e "\n${CYAN}Options:${RESET}"
        echo "1 - Enable Watchdog Service"
        echo "2 - Disable Watchdog Service"
        echo "3 - Start Watchdog Service (now)"
        echo "4 - Stop Watchdog Service (now)"
        echo "5 - Restart Watchdog Service"
        echo "6 - Back to Main Menu"
        echo -n -e "\n${CYAN}Select option [1-6]: ${RESET}"
        
        read -r OPTION </dev/tty
        
        case $OPTION in
            1)
                if [ ! -f "$CONF" ]; then
                    echo -e "\n${RED}[ERROR] Configuration not found!${RESET}"
                else
                    systemctl enable $WATCHDOG_SERVICE 2>/dev/null
                    echo -e "\n${GREEN}[SUCCESS] Watchdog service enabled${RESET}"
                fi
                ;;
            2)
                systemctl disable $WATCHDOG_SERVICE 2>/dev/null
                echo -e "\n${GREEN}[SUCCESS] Watchdog service disabled${RESET}"
                ;;
            3)
                systemctl start $WATCHDOG_SERVICE 2>/dev/null
                echo -e "\n${GREEN}[SUCCESS] Watchdog service started${RESET}"
                ;;
            4)
                systemctl stop $WATCHDOG_SERVICE 2>/dev/null
                echo -e "\n${GREEN}[SUCCESS] Watchdog service stopped${RESET}"
                ;;
            5)
                systemctl restart $WATCHDOG_SERVICE 2>/dev/null
                echo -e "\n${GREEN}[SUCCESS] Watchdog service restarted${RESET}"
                ;;
            6)
                return
                ;;
            *)
                echo -e "\n${RED}Invalid option${RESET}"
                ;;
        esac
        
        echo -e "\n${CYAN}Press Enter to continue...${RESET}"
        read -r </dev/tty
    done
}

manage_auto_restart() {
    while true; do
        clear
        echo -e "${CYAN}==== Auto-Restart Management ====${RESET}"
        service_status=$(systemctl is-active $AUTO_RESTART_TIMER 2>/dev/null || echo 'Not configured')
        echo -e "Current status: $service_status"
        echo -e "\n${CYAN}Options:${RESET}"
        echo "1 - Configure Auto-Restart"
        echo "2 - Enable Auto-Restart"
        echo "3 - Disable Auto-Restart"
        echo "4 - Start Auto-Restart Timer"
        echo "5 - Stop Auto-Restart Timer"
        echo "6 - Show next scheduled restart"
        echo "7 - Back to Main Menu"
        echo -n -e "\n${CYAN}Select option [1-7]: ${RESET}"
        
        read -r OPTION </dev/tty
        
        case $OPTION in
            1)
                if [ ! -f "$CONF" ]; then
                    echo -e "\n${RED}[ERROR] Configuration not found!${RESET}"
                else
                    echo -n -e "\n${CYAN}Enter restart interval in hours (0 to disable): ${RESET}"
                    read -r INTERVAL </dev/tty
                    
                    if [[ "$INTERVAL" =~ ^[0-9]+$ ]]; then
                        if [ "$INTERVAL" -eq 0 ]; then
                            systemctl stop $AUTO_RESTART_TIMER 2>/dev/null
                            systemctl disable $AUTO_RESTART_TIMER 2>/dev/null
                            echo -e "\n${GREEN}Auto-restart disabled${RESET}"
                        else
                            create_auto_restart_service "$INTERVAL"
                            systemctl enable $AUTO_RESTART_TIMER 2>/dev/null
                            systemctl start $AUTO_RESTART_TIMER 2>/dev/null
                            echo -e "\n${GREEN}Auto-restart configured for every $INTERVAL hours${RESET}"
                        fi
                    else
                        echo -e "\n${RED}Invalid interval${RESET}"
                    fi
                fi
                ;;
            2)
                systemctl enable $AUTO_RESTART_TIMER 2>/dev/null
                systemctl start $AUTO_RESTART_TIMER 2>/dev/null
                echo -e "\n${GREEN}Auto-restart enabled${RESET}"
                ;;
            3)
                systemctl stop $AUTO_RESTART_TIMER 2>/dev/null
                systemctl disable $AUTO_RESTART_TIMER 2>/dev/null
                echo -e "\n${GREEN}Auto-restart disabled${RESET}"
                ;;
            4)
                systemctl start $AUTO_RESTART_TIMER 2>/dev/null
                echo -e "\n${GREEN}Auto-restart timer started${RESET}"
                ;;
            5)
                systemctl stop $AUTO_RESTART_TIMER 2>/dev/null
                echo -e "\n${GREEN}Auto-restart timer stopped${RESET}"
                ;;
            6)
                if systemctl is-active $AUTO_RESTART_TIMER >/dev/null 2>&1; then
                    next_run=$(systemctl show -p NextElapseUSecRealtime $AUTO_RESTART_TIMER 2>/dev/null | cut -d= -f2)
                    if [ -n "$next_run" ] && [ "$next_run" != "0" ]; then
                        next_time=$(( ${next_run::-6} / 1000000 ))
                        echo -e "\n${CYAN}Next restart:${RESET} $(date -d @$next_time 2>/dev/null)"
                    else
                        echo -e "\n${YELLOW}No next restart scheduled${RESET}"
                    fi
                else
                    echo -e "\n${RED}Auto-restart timer is not active${RESET}"
                fi
                ;;
            7)
                return
                ;;
            *)
                echo -e "\n${RED}Invalid option${RESET}"
                ;;
        esac
        
        echo -e "\n${CYAN}Press Enter to continue...${RESET}"
        read -r </dev/tty
    done
}

manual_operations() {
    clear
    echo -e "${CYAN}══════ Manual Tunnel Operations ══════${RESET}"
    echo -e "\n${CYAN}Options:${RESET}"
    echo "1 - Restart tunnel manually"
    echo "2 - Check tunnel connection"
    echo "3 - Back to Main Menu"
    echo -n -e "\n${CYAN}Select option [1-3]: ${RESET}"
    
    read -r SUBOPTION </dev/tty
    
    case $SUBOPTION in
        1)
            if [ ! -f "$CONF" ]; then
                echo -e "\n${RED}[ERROR] Configuration not found!${RESET}"
            else
                source "$CONF"
                coordinated_restart "$ROLE" "$IP_LOCAL" "$IP_REMOTE"
                echo -e "\n${GREEN}Tunnel restarted${RESET}"
            fi
            ;;
        2)
            if [ ! -f "$CONF" ]; then
                echo -e "\n${RED}[ERROR] Configuration not found!${RESET}"
            else
                source "$CONF"
                if [ "$ROLE" = "IRAN" ]; then
                    TARGET="132.168.30.1"
                else
                    TARGET="132.168.30.2"
                fi
                
                echo -e "\nTesting connection to: $TARGET"
                timeout 3 bash -c "</dev/tcp/$TARGET/22" 2>/dev/null
                
                if [ $? -eq 0 ]; then
                    echo -e "\n${GREEN}Connection is OK${RESET}"
                else
                    echo -e "\n${RED}Connection failed${RESET}"
                fi
            fi
            ;;
        3)
            return
            ;;
        *)
            echo -e "\n${RED}Invalid option${RESET}"
            ;;
    esac
    
    echo -e "\n${CYAN}Press Enter to continue...${RESET}"
    read -r </dev/tty
}

system_operations() {
    clear
    echo -e "${CYAN}══════ System Operations ══════${RESET}"
    echo -e "\n${CYAN}Options:${RESET}"
    echo "1 - Full cleanup (uninstall everything)"
    echo "2 - View system logs"
    echo "3 - Back to Main Menu"
    echo -n -e "\n${CYAN}Select option [1-3]: ${RESET}"
    
    read -r SUBOPTION </dev/tty
    
    case $SUBOPTION in
        1)
            echo -e "\n${RED}WARNING! This will remove EVERYTHING${RESET}"
            echo -n "Are you absolutely sure? (type YES to confirm): "
            read -r CONFIRM </dev/tty
            
            if [ "$CONFIRM" = "YES" ]; then
                clean_all
                echo -e "\n${GREEN}Everything cleaned up${RESET}"
                echo -e "\nReturning to main menu in 3 seconds..."
                sleep 3
                return
            else
                echo -e "\n${YELLOW}Cancelled${RESET}"
            fi
            ;;
        2)
            echo -e "\n${CYAN}Tunnel Service Logs:${RESET}"
            journalctl -u $TUNNEL_SERVICE -n 10 --no-pager 2>/dev/null || echo "No logs available"
            
            echo -e "\n${CYAN}Watchdog Service Logs:${RESET}"
            journalctl -u $WATCHDOG_SERVICE -n 10 --no-pager 2>/dev/null || echo "No logs available"
            
            echo -e "\n${CYAN}Auto-Restart Logs:${RESET}"
            journalctl -u $AUTO_RESTART_SERVICE -n 10 --no-pager 2>/dev/null || echo "No logs available"
            ;;
        3)
            return
            ;;
        *)
            echo -e "\n${RED}Invalid option${RESET}"
            ;;
    esac
    
    echo -e "\n${CYAN}Press Enter to continue...${RESET}"
    read -r </dev/tty
}

# شروع برنامه اصلی
require_root

# تنظیم ترمینال برای خواندن صحیح
if [ -t 0 ]; then
    stty sane 2>/dev/null
fi

# اجرای منوی اصلی
simple_menu
