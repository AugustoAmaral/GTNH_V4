#!/bin/bash

# Script de controle rapido para GTNH V4 (macOS)
# Atalhos para os comandos mais usados

# Obtém o diretório do script
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONTROL_SCRIPT="$SCRIPT_DIR/server-control-mac.sh"

case "$1" in
    "")
        echo "=== Controle Rapido GTNH V4 (macOS) ==="
        echo ""
        echo "Atalhos disponiveis:"
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
