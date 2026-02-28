#!/usr/bin/env sh
# Script com auto-restart para Oracle Linux - GTNH V4
# Forge requires a configured set of both JVM and program arguments.

SERVER_DIR="/home/ubuntu/GTNH_V4"
cd "$SERVER_DIR"

# Configuração do auto-restart
RESTART_LOG="$SERVER_DIR/restart.log"
MAX_CRASHES=5          # Máximo de crashes consecutivos permitidos
CRASH_TIMEOUT=300      # 5 minutos entre crashes para resetar contador
crash_count=0
last_crash_time=0

# Função para log
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$RESTART_LOG"
}

# Função para verificar se deve reiniciar
should_restart() {
    current_time=$(date +%s)
    time_since_crash=$((current_time - last_crash_time))

    # Se passou tempo suficiente desde o último crash, reseta contador
    if [ $time_since_crash -gt $CRASH_TIMEOUT ]; then
        crash_count=0
    fi

    if [ $crash_count -ge $MAX_CRASHES ]; then
        log_message "ERRO: Muitos crashes consecutivos ($crash_count). Parando auto-restart."
        log_message "Para reiniciar manualmente, execute novamente o script ou delete o arquivo restart.log"
        return 1
    fi

    return 0
}

log_message "=== Iniciando servidor GTNH V4 com auto-restart (Oracle Linux) ==="
log_message "Script PID: $$"

# Configura Java 21
JAVA_BIN="/usr/lib/jvm/java-21-openjdk-arm64/bin/java"
if [ ! -f "$JAVA_BIN" ]; then
    log_message "ERRO: Java 21 não encontrado em $JAVA_BIN!"
    log_message "Instale com: sudo apt install openjdk-21-jdk"
    exit 1
fi
log_message "Usando Java: $JAVA_BIN"

# Loop principal de auto-restart
while true; do
    log_message "Iniciando servidor... (Crash count: $crash_count)"

    # Executa o servidor GTNH V4 com Java 21 + lwjgl3ify
    "$JAVA_BIN" \
        -Xms6G -Xmx10G \
        -XX:+UseG1GC \
        -XX:+UnlockExperimentalVMOptions \
        -XX:G1NewSizePercent=30 \
        -XX:G1MaxNewSizePercent=40 \
        -XX:G1HeapRegionSize=16M \
        -XX:G1ReservePercent=20 \
        -XX:G1HeapWastePercent=5 \
        -XX:G1MixedGCCountTarget=4 \
        -XX:InitiatingHeapOccupancyPercent=20 \
        -XX:G1MixedGCLiveThresholdPercent=90 \
        -XX:MaxGCPauseMillis=130 \
        -XX:SurvivorRatio=32 \
        -XX:MaxTenuringThreshold=1 \
        -XX:+AlwaysPreTouch \
        -XX:+UseStringDeduplication \
        -XX:+ParallelRefProcEnabled \
        -XX:+PerfDisableSharedMem \
        -XX:+DisableExplicitGC \
        -XX:+UseCompressedOops \
        -Dfml.readTimeout=180 \
        @java9args.txt \
        -jar lwjgl3ify-forgePatches.jar nogui

    # Captura o código de saída
    exit_code=$?
    current_time=$(date +%s)

    # Se saída foi normal (0), reseta contador e sai
    if [ $exit_code -eq 0 ]; then
        log_message "Servidor encerrado normalmente. Finalizando auto-restart."
        break
    fi

    # Se houve crash, incrementa contador
    crash_count=$((crash_count + 1))
    last_crash_time=$current_time

    log_message "CRASH DETECTADO! Código de saída: $exit_code (Crash #$crash_count)"

    # Verifica se deve continuar tentando
    if ! should_restart; then
        break
    fi

    # Aguarda um pouco antes de reiniciar
    log_message "Reiniciando em 10 segundos..."
    sleep 10
done

log_message "=== Script de auto-restart finalizado ==="
