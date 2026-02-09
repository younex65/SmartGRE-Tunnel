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
STATE_FILE="/var/run/1plus-gre.state"

require_root(){ [ "$EUID" -ne 0 ] && { echo Run as root; exit 1; }; }

get_ip(){
  for s in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
    ip=$(curl -4 -s --max-time 3 $s | tr -d '\n\r')
    [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && echo $ip && return
  done
  hostname -I | awk '{print $1}'
}

add_iran(){
 ip tunnel add $TUN mode gre local $1 remote $2 ttl 255 2>/dev/null
 ip link set $TUN up
 ip addr add 132.168.30.2/30 dev $TUN 2>/dev/null
 sysctl -w net.ipv4.ip_forward=1 >/dev/null
 iptables -t nat -A PREROUTING -p tcp --dport 22 -j DNAT --to-destination 132.168.30.2
 iptables -t nat -A PREROUTING -j DNAT --to-destination 132.168.30.1
 iptables -t nat -A POSTROUTING -j MASQUERADE
}

add_foreign(){
 ip tunnel add $TUN mode gre local $1 remote $2 ttl 255 2>/dev/null
 ip link set $TUN up
 ip addr add 132.168.30.1/30 dev $TUN 2>/dev/null
 iptables -A INPUT --proto icmp -j DROP
}

clean_all(){
 systemctl stop $WATCHDOG_SERVICE 2>/dev/null
 systemctl disable $WATCHDOG_SERVICE 2>/dev/null
 systemctl stop $TUNNEL_SERVICE 2>/dev/null
 systemctl disable $TUNNEL_SERVICE 2>/dev/null
 rm -f /etc/systemd/system/$WATCHDOG_SERVICE /etc/systemd/system/$TUNNEL_SERVICE
 rm -f /usr/local/bin/1plus-gre-*
 ip link set $TUN down 2>/dev/null
 ip tunnel del $TUN 2>/dev/null
 iptables -t nat -F; iptables -F
 rm -f $CONF $STATE_FILE
}

coordinated_restart(){
 local role=$1
 local local_ip=$2
 local remote_ip=$3
 
 echo $(date +%s) > $STATE_FILE
 
 ip link set $TUN down 2>/dev/null
 ip tunnel del $TUN 2>/dev/null
 iptables -t nat -F
 iptables -F
 sleep 2
 
 if [ "$role" = "IRAN" ]; then
  add_iran $local_ip $remote_ip
 else
  add_foreign $local_ip $remote_ip
 fi
}

create_tunnel_service(){
 # ایجاد اسکریپت راه‌اندازی تونل
 cat >/usr/local/bin/1plus-gre-setup.sh <<EOF
#!/bin/bash
source /etc/1plus-gre.conf 2>/dev/null || exit 0
if [ "\$ROLE" = "IRAN" ]; then
  ip tunnel add $TUN mode gre local \$IP_LOCAL remote \$IP_REMOTE ttl 255 2>/dev/null
  ip link set $TUN up
  ip addr add 132.168.30.2/30 dev $TUN 2>/dev/null
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  iptables -t nat -A PREROUTING -p tcp --dport 22 -j DNAT --to-destination 132.168.30.2
  iptables -t nat -A PREROUTING -j DNAT --to-destination 132.168.30.1
  iptables -t nat -A POSTROUTING -j MASQUERADE
else
  ip tunnel add $TUN mode gre local \$IP_LOCAL remote \$IP_REMOTE ttl 255 2>/dev/null
  ip link set $TUN up
  ip addr add 132.168.30.1/30 dev $TUN 2>/dev/null
  iptables -A INPUT --proto icmp -j DROP
fi
EOF

 # ایجاد اسکریپت توقف تونل
 cat >/usr/local/bin/1plus-gre-teardown.sh <<EOF
#!/bin/bash
ip link set $TUN down 2>/dev/null
ip tunnel del $TUN 2>/dev/null
iptables -t nat -F 2>/dev/null
iptables -F 2>/dev/null
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
 if [ -f \$STATE_FILE ]; then
  last_restart=\$(cat \$STATE_FILE)
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

show_status(){
 echo -e "\n${CYAN}=== Current Status ===${RESET}"
 
 if [ -f $CONF ]; then
  source $CONF 2>/dev/null
  echo "Role: $ROLE"
  echo "Local IP: $IP_LOCAL"
  echo "Remote IP: $IP_REMOTE"
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
 
 echo -e "\n${CYAN}Tunnel Interface:${RESET}"
 if ip link show $TUN 2>/dev/null >/dev/null; then
  echo -e "Status: ${GREEN}UP${RESET}"
  ip addr show $TUN | grep inet | sed 's/^[ \t]*//'
 else
  echo -e "Status: ${RED}DOWN${RESET}"
 fi
}

tunnel_service_menu(){
 while true; do
  clear
  echo -e "${CYAN}==== Tunnel Service Management ====${RESET}"
  echo -e "Current status: $(systemctl is-active $TUNNEL_SERVICE 2>/dev/null || echo 'Not installed')"
  echo -e "\n${CYAN}Options:${RESET}"
  echo "1 - Enable Tunnel Service (auto-start on boot)"
  echo "2 - Disable Tunnel Service"
  echo "3 - Start Tunnel Service (now)"
  echo "4 - Stop Tunnel Service (now)"
  echo "5 - Restart Tunnel Service"
  echo "6 - Back to Main Menu"
  echo -n -e "\n${CYAN}Select option [1-6]: ${RESET}"
  
  read OPTION
  
  case $OPTION in
   1)
     clear
     echo -e "${CYAN}==== Enable Tunnel Service ====${RESET}"
     
     if [ ! -f $CONF ]; then
       echo -e "\n${RED}[ERROR] Configuration not found! Please install server first.${RESET}"
       read -p "Press Enter to continue..."
       continue
     fi
     
     create_tunnel_service
     systemctl enable $TUNNEL_SERVICE
     
     if systemctl enable $TUNNEL_SERVICE 2>/dev/null; then
       echo -e "\n${GREEN}[SUCCESS] Tunnel service enabled (will auto-start on boot)${RESET}"
     else
       echo -e "\n${YELLOW}[WARNING] Failed to enable tunnel service${RESET}"
     fi
     read -p "Press Enter to continue..."
     ;;
     
   2)
     clear
     echo -e "${CYAN}==== Disable Tunnel Service ====${RESET}"
     
     systemctl disable $TUNNEL_SERVICE 2>/dev/null
     
     if systemctl disable $TUNNEL_SERVICE 2>/dev/null; then
       echo -e "\n${GREEN}[SUCCESS] Tunnel service disabled (will not auto-start)${RESET}"
     else
       echo -e "\n${YELLOW}[WARNING] Tunnel service might not be installed${RESET}"
     fi
     read -p "Press Enter to continue..."
     ;;
     
   3)
     clear
     echo -e "${CYAN}==== Start Tunnel Service ====${RESET}"
     
     systemctl start $TUNNEL_SERVICE 2>/dev/null
     
     if systemctl is-active $TUNNEL_SERVICE >/dev/null 2>&1; then
       echo -e "\n${GREEN}[SUCCESS] Tunnel service started${RESET}"
     else
       echo -e "\n${YELLOW}[WARNING] Failed to start tunnel service${RESET}"
     fi
     read -p "Press Enter to continue..."
     ;;
     
   4)
     clear
     echo -e "${CYAN}==== Stop Tunnel Service ====${RESET}"
     
     systemctl stop $TUNNEL_SERVICE 2>/dev/null
     
     if ! systemctl is-active $TUNNEL_SERVICE >/dev/null 2>&1; then
       echo -e "\n${GREEN}[SUCCESS] Tunnel service stopped${RESET}"
     else
       echo -e "\n${YELLOW}[WARNING] Failed to stop tunnel service${RESET}"
     fi
     read -p "Press Enter to continue..."
     ;;
     
   5)
     clear
     echo -e "${CYAN}==== Restart Tunnel Service ====${RESET}"
     
     systemctl restart $TUNNEL_SERVICE 2>/dev/null
     
     if systemctl is-active $TUNNEL_SERVICE >/dev/null 2>&1; then
       echo -e "\n${GREEN}[SUCCESS] Tunnel service restarted${RESET}"
     else
       echo -e "\n${YELLOW}[WARNING] Tunnel service might not be running${RESET}"
     fi
     read -p "Press Enter to continue..."
     ;;
     
   6)
     return
     ;;
     
   *)
     echo -e "\n${RED}[ERROR] Invalid option${RESET}"
     sleep 1
     ;;
  esac
 done
}

watchdog_service_menu(){
 while true; do
  clear
  echo -e "${CYAN}==== Watchdog Service Management ====${RESET}"
  echo -e "Current status: $(systemctl is-active $WATCHDOG_SERVICE 2>/dev/null || echo 'Not installed')"
  echo -e "\n${CYAN}Options:${RESET}"
  echo "1 - Enable Watchdog Service"
  echo "2 - Disable Watchdog Service"
  echo "3 - Start Watchdog Service (now)"
  echo "4 - Stop Watchdog Service (now)"
  echo "5 - Restart Watchdog Service"
  echo "6 - Back to Main Menu"
  echo -n -e "\n${CYAN}Select option [1-6]: ${RESET}"
  
  read OPTION
  
  case $OPTION in
   1)
     clear
     echo -e "${CYAN}==== Enable Watchdog Service ====${RESET}"
     
     if [ ! -f $CONF ]; then
       echo -e "\n${RED}[ERROR] Configuration not found! Please install server first.${RESET}"
       read -p "Press Enter to continue..."
       continue
     fi
     
     create_watchdog_service
     systemctl enable $WATCHDOG_SERVICE
     
     if systemctl enable $WATCHDOG_SERVICE 2>/dev/null; then
       echo -e "\n${GREEN}[SUCCESS] Watchdog service enabled${RESET}"
     else
       echo -e "\n${YELLOW}[WARNING] Failed to enable watchdog service${RESET}"
     fi
     read -p "Press Enter to continue..."
     ;;
     
   2)
     clear
     echo -e "${CYAN}==== Disable Watchdog Service ====${RESET}"
     
     systemctl disable $WATCHDOG_SERVICE 2>/dev/null
     
     if systemctl disable $WATCHDOG_SERVICE 2>/dev/null; then
       echo -e "\n${GREEN}[SUCCESS] Watchdog service disabled${RESET}"
     else
       echo -e "\n${YELLOW}[WARNING] Watchdog service might not be installed${RESET}"
     fi
     read -p "Press Enter to continue..."
     ;;
     
   3)
     clear
     echo -e "${CYAN}==== Start Watchdog Service ====${RESET}"
     
     systemctl start $WATCHDOG_SERVICE 2>/dev/null
     
     if systemctl is-active $WATCHDOG_SERVICE >/dev/null 2>&1; then
       echo -e "\n${GREEN}[SUCCESS] Watchdog service started${RESET}"
     else
       echo -e "\n${YELLOW}[WARNING] Failed to start watchdog service${RESET}"
     fi
     read -p "Press Enter to continue..."
     ;;
     
   4)
     clear
     echo -e "${CYAN}==== Stop Watchdog Service ====${RESET}"
     
     systemctl stop $WATCHDOG_SERVICE 2>/dev/null
     
     if ! systemctl is-active $WATCHDOG_SERVICE >/dev/null 2>&1; then
       echo -e "\n${GREEN}[SUCCESS] Watchdog service stopped${RESET}"
     else
       echo -e "\n${YELLOW}[WARNING] Failed to stop watchdog service${RESET}"
     fi
     read -p "Press Enter to continue..."
     ;;
     
   5)
     clear
     echo -e "${CYAN}==== Restart Watchdog Service ====${RESET}"
     
     systemctl restart $WATCHDOG_SERVICE 2>/dev/null
     
     if systemctl is-active $WATCHDOG_SERVICE >/dev/null 2>&1; then
       echo -e "\n${GREEN}[SUCCESS] Watchdog service restarted${RESET}"
     else
       echo -e "\n${YELLOW}[WARNING] Watchdog service might not be running${RESET}"
     fi
     read -p "Press Enter to continue..."
     ;;
     
   6)
     return
     ;;
     
   *)
     echo -e "\n${RED}[ERROR] Invalid option${RESET}"
     sleep 1
     ;;
  esac
 done
}

main_menu(){
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
  echo "6  - Manual Tunnel Operations"
  echo "7  - System Operations"
  echo "8  - Exit"
  echo -n -e "\n${CYAN}Select option [1-8]: ${RESET}"
  
  read OPTION
  
  case $OPTION in
   1|2)
     clear
     echo -e "${CYAN}══════ Install $( [ "$OPTION" = "1" ] && echo "IRAN" || echo "FOREIGN" ) Server ══════${RESET}"
     
     if [ "$OPTION" = 1 ]; then
       ROLE=IRAN
     else
       ROLE=FOREIGN
     fi
     
     LOCAL_IP=$(get_ip)
     read -p "Local server IP [$LOCAL_IP]: " USER_IP
     [ -n "$USER_IP" ] && LOCAL_IP=$USER_IP
     read -p "Enter opposite server IP: " REMOTE_IP
     
     if [ -z "$REMOTE_IP" ] || [ -z "$LOCAL_IP" ]; then
       echo -e "\n${RED}[ERROR] IP addresses cannot be empty${RESET}"
       read -p "Press Enter to continue..."
       continue
     fi
     
     # توقف سرویس‌های موجود
     systemctl stop $WATCHDOG_SERVICE 2>/dev/null
     systemctl stop $TUNNEL_SERVICE 2>/dev/null
     
     # حذف تونل قدیمی
     ip link set $TUN down 2>/dev/null
     ip tunnel del $TUN 2>/dev/null
     iptables -t nat -F 2>/dev/null
     iptables -F 2>/dev/null
     
     # ایجاد تونل جدید
     if [ "$ROLE" = "IRAN" ]; then
       add_iran $LOCAL_IP $REMOTE_IP
     else
       add_foreign $LOCAL_IP $REMOTE_IP
     fi
     
     # ذخیره تنظیمات
     echo ROLE=$ROLE > $CONF
     echo IP_LOCAL=$LOCAL_IP >> $CONF
     echo IP_REMOTE=$REMOTE_IP >> $CONF
     
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
     echo -e "Use ${CYAN}option 4${RESET} to manage tunnel service"
     echo -e "Use ${CYAN}option 5${RESET} to manage watchdog service"
     read -p "Press Enter to return to main menu..."
     ;;
     
   3)
     clear
     echo -e "${CYAN}══════ Reinstall Tunnel Only ══════${RESET}"
     
     if [ ! -f $CONF ]; then
       echo -e "\n${RED}[ERROR] Configuration not found! Please install server first.${RESET}"
       read -p "Press Enter to continue..."
       continue
     fi
     
     source $CONF
     
     # حذف و ایجاد مجدد تونل
     ip link set $TUN down 2>/dev/null
     ip tunnel del $TUN 2>/dev/null
     iptables -t nat -F 2>/dev/null
     iptables -F 2>/dev/null
     
     if [ "$ROLE" = "IRAN" ]; then
       add_iran $IP_LOCAL $IP_REMOTE
     else
       add_foreign $IP_LOCAL $IP_REMOTE
     fi
     
     echo -e "\n${GREEN}[SUCCESS] Tunnel reinstalled successfully${RESET}"
     read -p "Press Enter to return to main menu..."
     ;;
     
   4)
     tunnel_service_menu
     ;;
     
   5)
     watchdog_service_menu
     ;;
     
   6)
     clear
     echo -e "${CYAN}══════ Manual Tunnel Operations ══════${RESET}"
     echo -e "\n${CYAN}Options:${RESET}"
     echo "1 - Restart tunnel manually"
     echo "2 - Check tunnel connection"
     echo "3 - Show detailed tunnel info"
     echo "4 - Back to Main Menu"
     echo -n -e "\n${CYAN}Select option [1-4]: ${RESET}"
     
     read SUBOPTION
     
     case $SUBOPTION in
       1)
         clear
         echo -e "${CYAN}══════ Restart Tunnel Manually ══════${RESET}"
         
         if [ ! -f $CONF ]; then
           echo -e "\n${RED}[ERROR] Configuration not found!${RESET}"
           read -p "Press Enter to continue..."
           continue
         fi
         
         source $CONF
         coordinated_restart "$ROLE" "$IP_LOCAL" "$IP_REMOTE"
         
         echo -e "\n${GREEN}[SUCCESS] Tunnel restarted manually${RESET}"
         ;;
         
       2)
         clear
         echo -e "${CYAN}══════ Check Tunnel Connection ══════${RESET}"
         
         if [ ! -f $CONF ]; then
           echo -e "\n${RED}[ERROR] Configuration not found!${RESET}"
           read -p "Press Enter to continue..."
           continue
         fi
         
         source $CONF
         if [ "$ROLE" = "IRAN" ]; then
           TARGET="132.168.30.1"
         else
           TARGET="132.168.30.2"
         fi
         
         echo -e "Testing connection to: $TARGET"
         timeout 3 bash -c "</dev/tcp/$TARGET/22" 2>/dev/null
         
         if [ $? -eq 0 ]; then
           echo -e "\n${GREEN}[SUCCESS] Connection is OK${RESET}"
         else
           echo -e "\n${RED}[ERROR] Connection failed${RESET}"
         fi
         ;;
         
       3)
         clear
         echo -e "${CYAN}══════ Detailed Tunnel Info ══════${RESET}"
         echo -e "\n${CYAN}Tunnel Interface:${RESET}"
         ip link show $TUN 2>/dev/null || echo "Tunnel not found"
         
         echo -e "\n${CYAN}IP Address:${RESET}"
         ip addr show $TUN 2>/dev/null || echo "No IP address assigned"
         
         echo -e "\n${CYAN}Tunnel Details:${RESET}"
         ip tunnel show $TUN 2>/dev/null || echo "No tunnel details available"
         ;;
         
       4)
         continue
         ;;
         
       *)
         echo -e "\n${RED}[ERROR] Invalid option${RESET}"
         ;;
     esac
     
     read -p "Press Enter to return to main menu..."
     ;;
     
   7)
     clear
     echo -e "${CYAN}══════ System Operations ══════${RESET}"
     echo -e "\n${CYAN}Options:${RESET}"
     echo "1 - Full cleanup (uninstall everything)"
     echo "2 - View system logs"
     echo "3 - Check system dependencies"
     echo "4 - Back to Main Menu"
     echo -n -e "\n${CYAN}Select option [1-4]: ${RESET}"
     
     read SUBOPTION
     
     case $SUBOPTION in
       1)
         clear
         echo -e "${CYAN}══════ Full Cleanup ══════${RESET}"
         echo -e "${RED}╔══════════════════════════════════════╗${RESET}"
         echo -e "${RED}║           WARNING! DANGER!           ║${RESET}"
         echo -e "${RED}╚══════════════════════════════════════╝${RESET}"
         echo -e "\nThis will remove ${RED}EVERYTHING${RESET}:"
         echo "- All tunnel configurations"
         echo "- All systemd services"
         echo "- All iptables rules"
         echo "- All configuration files"
         echo -e "\n${RED}This action cannot be undone!${RESET}"
         echo -n -e "\nAre you absolutely sure? (type ${RED}YES${RESET} to confirm): "
         
         read CONFIRM
         
         if [ "$CONFIRM" = "YES" ]; then
           clean_all
           echo -e "\n${GREEN}[SUCCESS] Everything cleaned up${RESET}"
         else
           echo -e "\n${YELLOW}[INFO] Cleanup cancelled${RESET}"
         fi
         ;;
         
       2)
         clear
         echo -e "${CYAN}══════ System Logs ══════${RESET}"
         echo -e "\n${CYAN}Tunnel Service Logs:${RESET}"
         journalctl -u $TUNNEL_SERVICE -n 20 --no-pager 2>/dev/null || echo "No logs available"
         
         echo -e "\n${CYAN}Watchdog Service Logs:${RESET}"
         journalctl -u $WATCHDOG_SERVICE -n 20 --no-pager 2>/dev/null || echo "No logs available"
         ;;
         
       3)
         clear
         echo -e "${CYAN}══════ System Dependencies ══════${RESET}"
         echo -e "\n${CYAN}Checking required tools:${RESET}"
         
         # Check ip command
         if command -v ip >/dev/null 2>&1; then
           echo -e "ip tool: ${GREEN}OK${RESET}"
         else
           echo -e "ip tool: ${RED}MISSING${RESET}"
         fi
         
         # Check iptables
         if command -v iptables >/dev/null 2>&1; then
           echo -e "iptables: ${GREEN}OK${RESET}"
         else
           echo -e "iptables: ${RED}MISSING${RESET}"
         fi
         
         # Check systemctl
         if command -v systemctl >/dev/null 2>&1; then
           echo -e "systemctl: ${GREEN}OK${RESET}"
         else
           echo -e "systemctl: ${RED}MISSING${RESET}"
         fi
         
         # Check curl
         if command -v curl >/dev/null 2>&1; then
           echo -e "curl: ${GREEN}OK${RESET}"
         else
           echo -e "curl: ${YELLOW}WARNING${RESET} (auto IP detection may not work)"
         fi
         ;;
         
       4)
         continue
         ;;
         
       *)
         echo -e "\n${RED}[ERROR] Invalid option${RESET}"
         ;;
     esac
     
     read -p "Press Enter to return to main menu..."
     ;;
     
   8)
     clear
     echo -e "${CYAN}╔══════════════════════════════════════╗${RESET}"
     echo -e "${CYAN}║            Goodbye!                   ║${RESET}"
     echo -e "${CYAN}╚══════════════════════════════════════╝${RESET}"
     exit 0
     ;;
     
   *)
     echo -e "\n${RED}[ERROR] Invalid option${RESET}"
     sleep 1
     ;;
  esac
 done
}

# شروع برنامه
require_root
main_menu
