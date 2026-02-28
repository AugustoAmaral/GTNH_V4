#!/bin/bash

# Script de controle rápido para GTNH V4 (Oracle Linux)
# Atalhos para os comandos mais usados

SCRIPT_DIR="/home/ubuntu/GTNH_V4"
CONTROL_SCRIPT="$SCRIPT_DIR/server-control.sh"

case "$1" in
    "")
        echo "=== Controle Rápido GTNH V4 (Oracle Linux) ==="
        echo ""
        echo "Atalhos disponíveis:"
        echo "  s    - Status completo (servidor + backup)"
        echo "  start- Inicia servidor e backup"
        echo "  stop - Para servidor e backup"
        echo "  kill - Forca encerramento imediato"
        echo "  r    - Reinicia servidor e backup"
        echo "  log  - Logs do servidor"
        echo "  blog - Logs do backup"
        echo "  con  - Console do servidor"
        echo "  bcon - Console do backup"
        echo ""
        echo "Para ver todos os comandos: $0 help"
        ;;

    "s"|"status")
        $CONTROL_SCRIPT status-all
        ;;

    "start")
        $CONTROL_SCRIPT start-all
        ;;

    "stop")
        $CONTROL_SCRIPT stop-all
        ;;

    "kill")
        $CONTROL_SCRIPT kill
        ;;

    "r"|"restart")
        $CONTROL_SCRIPT restart-all
        ;;

    "log"|"logs")
        $CONTROL_SCRIPT logs
        ;;

    "blog"|"backup-logs")
        $CONTROL_SCRIPT backup-logs
        ;;

    "con"|"console")
        $CONTROL_SCRIPT console
        ;;

    "bcon"|"backup-console")
        $CONTROL_SCRIPT backup-console
        ;;

    "help"|"-h"|"--help")
        $CONTROL_SCRIPT
        ;;

    *)
        echo "Comando '$1' não reconhecido."
        echo "Use '$0' para ver os atalhos ou '$0 help' para todos os comandos."
        ;;
esac
