#!/usr/bin/env bash
# rollback-regiao.sh — método padrão de rollback de área do mundo no GTNH_V4.
#
# Reverte o bloco 3x3 (ou NxN) de arquivos de região que contém um ponto (x,z)
# para o estado de um commit alvo, com servidor parado, backup triplo e
# validação de sanidade do snapshot antes de escrever qualquer byte.
#
# Uso (do diretório do repo do servidor, ex. ~/GTNH_V4):
#   ./rollback-regiao.sh --x -1807 --z -6173                 # dry-run (padrão)
#   ./rollback-regiao.sh --x -1807 --z -6173 --apply         # executa
#
# Opções:
#   --x N --z N          coordenadas de bloco do ponto alvo (obrigatório)
#   --radius N           raio em arquivos de região (1 = 3x3, padrão; 2 = 5x5)
#   --commit SHA         commit alvo (padrão: pré-update 2.9, resolvido sozinho)
#   --dim PATH           pasta da dimensão (padrão: World/region = overworld)
#   --repo PATH          raiz do repo (padrão: $PWD, ou $GTNH_REPO)
#   --apply              sai do dry-run e executa de verdade
#   --keep-running       NÃO para o servidor (só permitido em dry-run)
#
# Variáveis de escape (use com consciência):
#   SKIP_SCAN=1          pula a validação de NBT do snapshot alvo
#   DELETE_MISSING=1     apaga arquivos de região que não existiam no commit alvo
#   NO_PUSH=1            faz os commits mas não dá push
#
set -euo pipefail

# ---------------------------------------------------------------- parâmetros
REPO="${GTNH_REPO:-$PWD}"
DIM="World/region"
RADIUS=1
TARGET_SHA=""
APPLY=0
KEEP_RUNNING=0
PX=""; PZ=""

# commit frio tirado com o servidor parado logo antes do update pra 2.9.0-beta-2
# (2026-08-12 23:05 UTC, "manual shutdown before update to 2.9.0-beta-2").
DEFAULT_SHA="b5e0d3f644"
UPDATE_GREP="Update GTNH server to 2.9.0-beta-2"

while [ $# -gt 0 ]; do
  case "$1" in
    --x) PX="$2"; shift 2 ;;
    --z) PZ="$2"; shift 2 ;;
    --radius) RADIUS="$2"; shift 2 ;;
    --commit) TARGET_SHA="$2"; shift 2 ;;
    --dim) DIM="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --keep-running) KEEP_RUNNING=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "opção desconhecida: $1" >&2; exit 2 ;;
  esac
done

[ -n "$PX" ] && [ -n "$PZ" ] || { echo "ERRO: --x e --z são obrigatórios" >&2; exit 2; }
[ "$APPLY" = 1 ] && [ "$KEEP_RUNNING" = 1 ] && { echo "ERRO: --keep-running só em dry-run" >&2; exit 2; }

cd "$REPO"
[ -f gtnh ] && [ -d World ] || { echo "ERRO: $REPO não parece o repo do GTNH_V4" >&2; exit 2; }

TS="$(date -u +%Y%m%d-%H%M)"
COLD="/tmp/gtnh-pre-rollback-region-$TS"
BRANCH="backup/pre-rollback-region-$TS"
WORK="$(mktemp -d /tmp/gtnh-rollback-check.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die() { printf '\033[31mERRO: %s\033[0m\n' "$*" >&2; exit 1; }

# ------------------------------------------------------- 1. quais arquivos
floordiv() { # floordiv <a> <b> — divisão com arredondamento pra baixo (bash trunca pro zero)
  local a=$1
  local b=$2
  local q=$(( a / b ))
  if [ $(( a % b )) -ne 0 ]; then
    if { [ "$a" -lt 0 ] && [ "$b" -gt 0 ]; } || { [ "$a" -gt 0 ] && [ "$b" -lt 0 ]; }; then q=$(( q - 1 )); fi
  fi
  echo "$q"
}

RX="$(floordiv "$PX" 512)"
RZ="$(floordiv "$PZ" 512)"
CX="$(floordiv "$PX" 16)"
CZ="$(floordiv "$PZ" 16)"

FILES=""
for dz in $(seq "$(( -RADIUS ))" "$RADIUS"); do
  for dx in $(seq "$(( -RADIUS ))" "$RADIUS"); do
    FILES="$FILES $DIM/r.$(( RX + dx )).$(( RZ + dz )).mca"
  done
done
N_FILES=$(echo $FILES | wc -w | tr -d ' ')

say "Alvo geográfico"
cat <<EOF
  ponto          : x=$PX z=$PZ
  chunk          : ($CX, $CZ)
  região central : r.$RX.$RZ.mca   (dim: $DIM)
  raio           : $RADIUS  ->  $N_FILES arquivos
  área revertida : x de $(( (RX - RADIUS) * 512 )) a $(( (RX + RADIUS) * 512 + 511 )) | z de $(( (RZ - RADIUS) * 512 )) a $(( (RZ + RADIUS) * 512 + 511 ))
EOF

# ------------------------------------------------------- 2. qual commit
say "Resolvendo o commit alvo"
if [ -z "$TARGET_SHA" ]; then
  if git cat-file -e "${DEFAULT_SHA}^{commit}" 2>/dev/null; then
    TARGET_SHA="$DEFAULT_SHA"
    echo "  usando o commit pré-update conhecido: $DEFAULT_SHA"
  else
    echo "  $DEFAULT_SHA não existe neste histórico (filter-repo de 2026-09-06?); procurando pelo update"
    UPD="$(git log --all --format='%H' --grep="$UPDATE_GREP" | tail -1)"
    [ -n "$UPD" ] || die "não achei o commit do update ('$UPDATE_GREP'). Passe --commit <sha> na mão."
    TARGET_SHA="$(git rev-parse "$UPD^")"
    echo "  update  : $UPD"
    echo "  pai dele: $TARGET_SHA  <- alvo"
  fi
fi
TARGET_SHA="$(git rev-parse "$TARGET_SHA")"
git log -1 --format='  alvo    : %H%n  data    : %ci%n  mensagem: %s' "$TARGET_SHA"

# o snapshot alvo é "o momento do update" só se o mundo não mudou entre ele e o commit do update
UPD_SHA="$(git log --all --format='%H' --grep="$UPDATE_GREP" | tail -1 || true)"
if [ -n "$UPD_SHA" ]; then
  DIFF_UPD="$(git diff --stat "$TARGET_SHA" "$UPD_SHA" -- $FILES || true)"
  if [ -z "$DIFF_UPD" ]; then
    echo "  sanidade: as regiões são byte-idênticas entre o alvo e o commit do update — sem ambiguidade."
  else
    echo "  ATENÇÃO: as regiões MUDARAM entre o alvo e o commit do update:"
    echo "$DIFF_UPD" | sed 's/^/    /'
  fi
fi

# ------------------------------------------------------- 3. inventário dos arquivos
say "Inventário (atual x alvo)"
MISSING=""
IDENTICAL=""
printf '  %-28s %12s %12s  %s\n' ARQUIVO ATUAL ALVO ESTADO
for f in $FILES; do
  now_sz="-"; [ -f "$f" ] && now_sz="$(wc -c < "$f" | tr -d ' ')"
  if git cat-file -e "$TARGET_SHA:$f" 2>/dev/null; then
    tgt_sz="$(git cat-file -s "$TARGET_SHA:$f")"
    if [ -f "$f" ] && git diff --quiet "$TARGET_SHA" -- "$f"; then
      state="idêntico (no-op)"; IDENTICAL="$IDENTICAL $f"
    else
      state="será revertido"
    fi
  else
    tgt_sz="-"; state="NÃO EXISTIA no alvo"; MISSING="$MISSING $f"
  fi
  printf '  %-28s %12s %12s  %s\n' "$(basename "$f")" "$now_sz" "$tgt_sz" "$state"
done

if command -v python3 >/dev/null 2>&1; then
  echo
  echo "  chunks gravados por arquivo (header de offsets):"
  for f in $FILES; do
    cur="$( [ -f "$f" ] && python3 - "$f" <<'PY' || echo -
import sys,struct
d=open(sys.argv[1],'rb').read(4096)
print(sum(1 for i in range(0,4096,4) if struct.unpack('>I',d[i:i+4])[0]>>8))
PY
)"
    tgt="$(git cat-file -e "$TARGET_SHA:$f" 2>/dev/null && git show "$TARGET_SHA:$f" | python3 -c '
import sys,struct
d=sys.stdin.buffer.read(4096)
print(sum(1 for i in range(0,4096,4) if struct.unpack(">I",d[i:i+4])[0]>>8))' || echo -)"
    printf '    %-28s atual=%-6s alvo=%s\n' "$(basename "$f")" "$cur" "$tgt"
  done
fi

[ -n "$MISSING" ] && cat <<EOF

  !! Arquivos ausentes no commit alvo:$MISSING
     Por padrão eles são DEIXADOS COMO ESTÃO (terreno explorado depois do update
     continua existindo). Pra apagá-los — o mundo regenera o terreno do zero no
     próximo carregamento — rode com DELETE_MISSING=1.
EOF

# ------------------------------------------------------- 4. sanidade do snapshot alvo
say "Validação de NBT do snapshot alvo (tools/ScanRegions)"
if [ "${SKIP_SCAN:-0}" = 1 ]; then
  echo "  PULADA por SKIP_SCAN=1 — você está aceitando restaurar chunk possivelmente rasgado."
elif [ ! -f tools/ScanRegions.java ]; then
  echo "  tools/ScanRegions.java não existe neste repo. Sem scanner não há validação."
  [ "$APPLY" = 1 ] && die "recuse-se a aplicar sem scan (ou force com SKIP_SCAN=1)"
else
  mkdir -p "$WORK/target/region" "$WORK/sr"
  for f in $FILES; do
    git cat-file -e "$TARGET_SHA:$f" 2>/dev/null && git show "$TARGET_SHA:$f" > "$WORK/target/region/$(basename "$f")"
  done
  javac -d "$WORK/sr" tools/ScanRegions.java 2>&1 | sed 's/^/    /'
  SCAN_OUT="$WORK/scan.txt"
  java -cp "$WORK/sr" ScanRegions "$WORK/target" > "$SCAN_OUT" 2>&1 || true
  tail -20 "$SCAN_OUT" | sed 's/^/    /'
  if grep -Eq 'BAD[^0-9]*0([^0-9]|$)' "$SCAN_OUT" && ! grep -Eq 'BAD[^0-9]*[1-9]' "$SCAN_OUT"; then
    echo "  OK: BAD=0 no snapshot alvo."
  else
    echo "  ATENÇÃO: não consegui confirmar BAD=0 (saída completa em $SCAN_OUT)."
    [ "$APPLY" = 1 ] && die "snapshot alvo não validado — não vou escrever. Confira o scan e use SKIP_SCAN=1 só se souber o que está fazendo."
  fi
fi

# ------------------------------------------------------- 5. estado do servidor
say "Estado do servidor"
./gtnh status || true
echo "  lock: $(cat state/active-host.json 2>/dev/null || echo '??')"

if [ "$APPLY" != 1 ]; then
  cat <<EOF

=========================================================================
DRY-RUN. Nada foi tocado. Pra executar, repita o comando com --apply.
A execução vai, nesta ordem:
  1. ./gtnh cmd list  (aborta se tiver alguém online)
  2. ./gtnh stop
  3. ./gtnh backup                      -> commit PRÉ-revert
  4. branch $BRANCH + push
  5. cp -a dos $N_FILES arquivos pra $COLD
  6. git checkout $TARGET_SHA -- <arquivos>
  7. git diff --stat (tem que dar vazio) + scan dos arquivos já no disco
  8. commit PÓS-revert + push
  9. ./gtnh start e espera pelo "Done"
=========================================================================
EOF
  exit 0
fi

# ------------------------------------------------------- 6. execução
say "1/9 Conferindo jogadores online"
LIST="$(./gtnh cmd list 2>&1 || true)"
echo "  $LIST"
echo "$LIST" | grep -Eq 'There are 0|0/[0-9]+ players' || die "tem gente online (ou RCON não respondeu). Abortando."

say "2/9 Parando o servidor"
./gtnh stop
sleep 3
./gtnh status || true

say "3/9 Commit PRÉ-revert"
./gtnh backup || echo "  (./gtnh backup retornou erro — provavelmente nada pra commitar)"
if [ -n "$(git status --porcelain)" ]; then
  git add -A
  git commit -m "Pre-rollback snapshot before region revert around ($PX,$PZ) [keep]"
fi
[ -z "$(git status --porcelain)" ] || die "working tree ainda sujo depois do backup — resolva antes de continuar"
PRE_SHA="$(git rev-parse HEAD)"
echo "  pré-revert: $PRE_SHA"

say "4/9 Branch de segurança"
git branch "$BRANCH" "$PRE_SHA"
if [ "${NO_PUSH:-0}" != 1 ]; then git push -u origin "$BRANCH"; fi

say "5/9 Cópia fria fora do repo"
mkdir -p "$COLD"
for f in $FILES; do [ -f "$f" ] && cp -a "$f" "$COLD/"; done
ls -l "$COLD" | sed 's/^/  /'

say "6/9 Checkout dos arquivos de região"
for f in $FILES; do
  if git cat-file -e "$TARGET_SHA:$f" 2>/dev/null; then
    git checkout "$TARGET_SHA" -- "$f"
    echo "  revertido: $f"
  elif [ "${DELETE_MISSING:-0}" = 1 ] && [ -f "$f" ]; then
    git rm -q "$f"; echo "  APAGADO (não existia no alvo): $f"
  else
    echo "  mantido como está (ausente no alvo): $f"
  fi
done

say "7/9 Verificação pós-checkout"
for f in $FILES; do
  git cat-file -e "$TARGET_SHA:$f" 2>/dev/null || continue
  D="$(git diff --stat "$TARGET_SHA" -- "$f")"
  [ -z "$D" ] || die "arquivo $f não ficou byte-idêntico ao alvo"
done
echo "  todos os arquivos revertidos são byte-idênticos ao commit alvo."
if [ "${SKIP_SCAN:-0}" != 1 ] && [ -d "$WORK/sr" ]; then
  mkdir -p "$WORK/live/region"
  for f in $FILES; do [ -f "$f" ] && cp "$f" "$WORK/live/region/"; done
  java -cp "$WORK/sr" ScanRegions "$WORK/live" 2>&1 | tail -10 | sed 's/^/  /'
fi

say "8/9 Commit PÓS-revert + push"
git add -A
git commit -m "Rollback region $DIM around ($PX,$PZ) to $TARGET_SHA (pre-2.9 update), ${N_FILES} region files [keep]"
POST_SHA="$(git rev-parse HEAD)"
if [ "${NO_PUSH:-0}" != 1 ]; then git push; fi
echo "  pós-revert: $POST_SHA"

say "9/9 Subindo o servidor"
# "Done (" antigo no latest.log daria falso positivo: conto antes e exijo uma
# ocorrência NOVA (ou o log ter rotacionado, que é o caso normal de boot).
PRE_DONE=0; PRE_SIZE=0
if [ -f logs/latest.log ]; then
  PRE_DONE="$(grep -c 'Done (' logs/latest.log || true)"
  PRE_SIZE="$(wc -c < logs/latest.log | tr -d ' ')"
fi
./gtnh start
echo "  aguardando 'Done' no log (até 5 min)..."
UP=0
for i in $(seq 1 60); do
  sleep 5
  if [ -f logs/latest.log ]; then
    NOW_DONE="$(grep -c 'Done (' logs/latest.log || true)"
    NOW_SIZE="$(wc -c < logs/latest.log | tr -d ' ')"
    if [ "$NOW_SIZE" -lt "$PRE_SIZE" ]; then
      [ "$NOW_DONE" -ge 1 ] && UP=1
    else
      [ "$NOW_DONE" -gt "$PRE_DONE" ] && UP=1
    fi
  fi
  [ "$UP" = 1 ] && { echo "  servidor no ar (Done novo no log)."; break; }
  if [ -f .run-marker ] && [ -n "$(find crash-reports -maxdepth 1 -name 'crash-*-server.txt' -newer .run-marker -print 2>/dev/null | head -1)" ]; then
    echo "  !! crash report novo apareceu — veja crash-reports/"; break
  fi
done
[ "$UP" = 1 ] || echo "  NÃO vi 'Done' novo. Se não houve crash, pode ser o prompt do FML (veja o rodapé)."
./gtnh status || true

cat <<EOF

=========================================================================
FEITO.
  pré-revert : $PRE_SHA   (branch $BRANCH)
  pós-revert : $POST_SHA
  cópia fria : $COLD

Se der ruim, desfazer é:
  ./gtnh stop
  git checkout $PRE_SHA -- $DIM
  git commit -am "Undo region rollback around ($PX,$PZ)"
  git push && ./gtnh start

Se o boot parecer travado sem crash: provavelmente é o prompt do FML
(o pack não roda mais com -Dfml.queryResult=confirm).
  screen -r gtnh  ->  /fml confirm  ->  Ctrl+A D
=========================================================================
EOF
