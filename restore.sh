#!/data/data/com.termux/files/usr/bin/bash

########################################
# Check ROOT
########################################

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run as root (su)"
  exit 1
fi
########################################

set -e

DB_DIR="/data/user_de/0/com.miui.home/databases"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

sql_escape() {
  printf "%s" "$1" | sed "s/'/''/g"
}

########################################
# Checks
########################################

if ! command -v sqlite3 >/dev/null 2>&1; then

  echo
  echo "[!] sqlite3 not found"
  echo
  read -rp "Install sqlite3 now? [Y/n]: " answer

  answer=${answer:-Y}

  case "$answer" in
  Y | y)

    echo
    echo "[+] Installing sqlite..."
    echo

    # pkg может чудить под root, поэтому временно отключаем set -e
    set +e
    pkg install -y sqlite
    set -e

    if ! command -v sqlite3 >/dev/null 2>&1; then
      echo
      echo "[!] sqlite3 is still unavailable."
      echo "[!] Please install/fix it manually."
      exit 1
    fi
    ;;
  *)
    echo
    echo "[!] sqlite3 is required."
    exit 1
    ;;
  esac

fi

mapfile -t EXPORTS < <(
  find "$SCRIPT_DIR/export" -mindepth 1 -maxdepth 1 -type d | sort
)

ecount=${#EXPORTS[@]}

[ "$ecount" -gt 0 ] || {
  echo "ERROR: export folders not found"
  exit 1
}

if [ "$ecount" -eq 1 ]; then

  EXPORT_DIR="${EXPORTS[0]}"

else

  echo
  echo "Found exports:"
  echo

  i=1
  for e in "${EXPORTS[@]}"; do
    echo "$i) $(basename "$e")"
    i=$((i + 1))
  done

  echo
  read -rp "Select export: " num

  idx=$((num - 1))
  EXPORT_DIR="${EXPORTS[$idx]}"
fi

mapfile -t FOLDER_LAYOUTS < <(
  find "$EXPORT_DIR/folders" -type f -name 'layout.txt' 2>/dev/null | sort
)

mapfile -t DESKTOP_LAYOUTS < <(
  find "$EXPORT_DIR/desktops" -type f -name 'layout.txt' 2>/dev/null | sort
)

mapfile -t WIDGET_LAYOUTS < <(
  find "$EXPORT_DIR/widgets" -type f -name 'layout.txt' 2>/dev/null | sort
)

echo "FOLDERS=${#FOLDER_LAYOUTS[@]}"
echo "DESKTOPS=${#DESKTOP_LAYOUTS[@]}"
echo "WIDGETS=${#WIDGET_LAYOUTS[@]}"

[ "${#FOLDER_LAYOUTS[@]}" -gt 0 ] || {
  echo "ERROR: no folder layouts found"
  exit 1
}

########################################
# DB loop
########################################

########################################
# Target DB selection
########################################

# Берем имя базы из названия выбранной папки экспорта
TARGET_DB_NAME="$(basename "$EXPORT_DIR").db"
TARGET_DB_PATH="$DB_DIR/$TARGET_DB_NAME"

# Проверяем, существует ли нужная база
if [ ! -f "$TARGET_DB_PATH" ]; then
  echo "ERROR: Target database $TARGET_DB_NAME not found in $DB_DIR"
  exit 1
fi

# Указываем скрипту работать ТОЛЬКО с этой базой
SELECTED_DBS=("$TARGET_DB_PATH")

echo "TARGET DB=[$TARGET_DB_NAME]"

for DB in "${SELECTED_DBS[@]}"; do

  # Вынесли бекап и лог ДО цикла перебора папок!
  echo
  echo "========================================"
  echo "[+] Processing: $(basename "$DB")"
  echo "========================================"
  echo

  backup="${DB}.$(date +%d-%m-%Y_%H-%M-%S).bak"
  cp -a "$DB" "$backup"
  echo "[+] Backup created: $backup"
  echo

  for LAYOUT in "${FOLDER_LAYOUTS[@]}"; do

    if grep -q '^FOLDER ' "$LAYOUT"; then
      LAYOUT_TYPE="folder"
    else
      LAYOUT_TYPE="desktop"
    fi

    ########################################
    # Read folder name
    ########################################

    if [ "$LAYOUT_TYPE" = "folder" ]; then
      folder_name=$(grep '^FOLDER ' "$LAYOUT" | head -n1 | cut -d' ' -f2-)
      safe_folder_name=$(sql_escape "$folder_name")
    fi

    desktop_screen=$(grep '^SCREEN ' "$LAYOUT" | awk '{print $2}')
    cellX=$(grep '^CELLX ' "$LAYOUT" | awk '{print $2}')
    cellY=$(grep '^CELLY ' "$LAYOUT" | awk '{print $2}')

    [ -n "$desktop_screen" ] || {
      echo "ERROR: no SCREEN line"
      exit 1
    }

    [ -n "$cellX" ] || {
      echo "ERROR: no CELLX line"
      exit 1
    }

    [ -n "$cellY" ] || {
      echo "ERROR: no CELLY line"
      exit 1
    }

    db_cellX=$((cellX - 1))
    db_cellY=$((cellY - 1))

    shortcut_count=$(
      grep -Ev '^(FOLDER|SCREEN|CELLX|CELLY) ' "$LAYOUT" |
        grep -c '^[^[:space:]]'
    )

    [ "$shortcut_count" -gt 0 ] || {
      echo "ERROR: no shortcuts in layout"
      exit 1
    }

    ########################################
    # Verify shortcuts from layout->database
    ########################################

    missing=0
    declare -A ID_MAP

    while IFS='|' read -r col1 col2 col3 col4 col5; do
      [ -z "$col1" ] && continue

      # Определяем формат строки и ПРИСВАИВАЕМ ПЕРЕМЕННЫЕ
      if [ -n "$col5" ]; then
        # Новый формат: title | profileId | hexIntent | cellX | cellY
        title="$col1"
        profile_id="$col2"
        hex_intent="$col3"
        # cellX/cellY здесь нам не нужны для поиска ID

        profile_cond="AND IFNULL(profileId, 0)=$profile_id"
        if [ "$hex_intent" = "NONE" ]; then
          intent_cond="AND intent IS NULL"
        else
          intent_cond="AND UPPER(hex(intent))='$hex_intent'"
        fi
      else
        # Старый формат: title | cellX | cellY
        title="$col1"
        profile_id="0"
        hex_intent="NONE"

        profile_cond=""
        intent_cond=""
      fi

      # Теперь safe_title точно содержит имя!
      safe_title=$(sql_escape "$title")

      # Ищем все ID, подходящие под условия
      sids=$(sqlite3 "$DB" "SELECT _id FROM favorites WHERE title='$safe_title' $profile_cond $intent_cond;")

      # Считаем количество строк в ответе
      count=$(echo "$sids" | awk 'NF{c++} END{print c+0}')

      if [ "$count" -gt 1 ]; then
        echo "[!] Duplicate found (using first of $count): $title"
        sid=$(echo "$sids" | head -n 1) # Берем первый
      elif [ -z "$sids" ]; then
        echo "[!] Missing in DB: $title"
        missing=$((missing + 1))
        continue
      else
        sid="$sids" # Нашли ровно один
      fi

      # Генерируем уникальный ключ
      key=$(printf '%s\037%s\037%s' "$title" "$profile_id" "$hex_intent")

      if [[ -v ID_MAP["$key"] ]]; then
        echo "[!] Duplicate key in export/import map:"
        echo "    title=$title"
        echo "    profileId=$profile_id"
        echo "    intent=$hex_intent"
        echo "    old_id=${ID_MAP[$key]}"
        echo "    new_id=$sid"
        continue
      fi

      # Сохраняем в массив
      ID_MAP["$key"]="$sid"

    done < <(
      grep -Ev '^(FOLDER|SCREEN|CELLX|CELLY) ' "$LAYOUT" |
        grep -v '^[[:space:]]*$'
    )

    [ "$missing" -eq 0 ] || {
      echo "[!] Aborting $(basename "$DB")"
      continue
    }

    ########################################
    # Find folder
    ########################################

    folder_id=$(sqlite3 "$DB" "
      SELECT _id
      FROM favorites
      WHERE title='$safe_folder_name'
      AND itemType=2
      LIMIT 1;
      ")

    ########################################
    # Create folder if missing
    ########################################

    if [ -z "$folder_id" ]; then

      echo "[+] Folder '$folder_name' not found"

      next_id=$(
        sqlite3 "$DB" "
          SELECT IFNULL(MAX(_id),0)+1
          FROM favorites;
          "
      )

      sqlite3 "$DB" "
          INSERT INTO favorites (
          _id,
          title,
          container,
          screen,
          cellX,
          cellY,
          spanX,
          spanY,
          itemType,
          appWidgetId,
          itemFlags,
          profileId,
          originWidgetId
          )
          VALUES (
          $next_id,
          '$safe_folder_name',
          -100,
          $desktop_screen,
          $db_cellX,
          $db_cellY,
          1,
          1,
          2,
          -1,
          0,
          0,
          -1
          );
          "

      folder_id=$next_id

      echo "[+] Folder created: $folder_id"

    else

      echo "[+] Folder found: $folder_id"

      sqlite3 "$DB" "
          UPDATE favorites
          SET
          screen=$desktop_screen,
          cellX=$db_cellX,
          cellY=$db_cellY
          WHERE _id=$folder_id;
          "

    fi

    ########################################
    # Restore contents
    ########################################

    while IFS='|' read -r col1 col2 col3 col4 col5; do
      [ -z "$col1" ] && continue

      if [ -n "$col5" ]; then

        title="$col1"
        profile_id="$col2"
        hex_intent="$col3"

        cellX="$col4"
        cellY="$col5"

        db_shortcut_cellX=$((cellX - 1))
        db_shortcut_cellY=$((cellY - 1))

      else

        title="$col1"

        cellX="$col2"
        cellY="$col3"

        profile_id="0"
        hex_intent="NONE"

        db_shortcut_cellX=$cellX
        db_shortcut_cellY=$cellY

      fi

      case "$cellX" in
      '' | *[!0-9]*)
        echo "    [!] Error: Invalid cellX '$cellX' for '$title'. Skipping."
        continue
        ;;
      esac
      case "$cellY" in
      '' | *[!0-9]*)
        echo "    [!] Error: Invalid cellY '$cellY' for '$title'. Skipping."
        continue
        ;;
      esac
      # ---------------------

      # Генерируем такой же ключ для поиска
      key=$(printf '%s\037%s\037%s' "$title" "$profile_id" "$hex_intent")

      # Берем ID из массива
      shortcut_id="${ID_MAP["$key"]}"

      if [ -n "$shortcut_id" ]; then

        sqlite3 "$DB" "
            UPDATE favorites
            SET
            container=$folder_id,
            screen=-1,
            cellX=$db_shortcut_cellX,
            cellY=$db_shortcut_cellY
            WHERE _id=$shortcut_id;
            "

        echo "    -> Restored: $title (ID: $shortcut_id)"

      else

        echo "    [!] Warning: Could not find ID for $title in map"

      fi

    done < <(
      grep -Ev '^(FOLDER|SCREEN|CELLX|CELLY) ' "$LAYOUT" |
        grep -v '^[[:space:]]*$'
    )

  done

  ########################################
  # Restore Desktops
  ########################################
  for LAYOUT2 in "${DESKTOP_LAYOUTS[@]}"; do
    desktop_screen=""

    while IFS= read -r line; do
      [ -z "$line" ] && continue

      # Ловим строку экрана и обновляем переменную
      if [[ "$line" == SCREEN\ * ]]; then
        desktop_screen=$(echo "$line" | awk '{print $2}')
        continue
      fi

      # Парсим строку с ярлыком
      IFS='|' read -r title profile_id hex_intent cellX cellY <<<"$line"

      [ -z "$title" ] && continue

      safe_title=$(sql_escape "$title")

      # Если hex_intent == NONE, значит это папка (itemType=2)
      if [ "$hex_intent" = "NONE" ]; then
        sid=$(sqlite3 "$DB" "
          SELECT _id
          FROM favorites
          WHERE title='$safe_title' AND itemType=2
          LIMIT 1;
          ")
      else
        # Иначе это приложение или ярлык (itemType != 2)
        sid=$(sqlite3 "$DB" "
          SELECT _id
          FROM favorites
          WHERE title='$safe_title' AND itemType!=2
          LIMIT 1;
          ")
      fi

      [ -n "$sid" ] || continue

      db_shortcut_cellX=$((cellX - 1))
      db_shortcut_cellY=$((cellY - 1))

      sqlite3 "$DB" "
        UPDATE favorites
        SET
        container=-100,
        screen=$desktop_screen,
        cellX=$db_shortcut_cellX,
        cellY=$db_shortcut_cellY
        WHERE _id=$sid;
        "

    done <"$LAYOUT2"
  done

  ########################################
  # Restore Widgets
  ########################################
  for LAYOUT3 in "${WIDGET_LAYOUTS[@]}"; do
    while IFS='|' read -r w_type w_screen w_cellX w_cellY w_spanX w_spanY w_provider; do
      [ "$w_type" != "WIDGET" ] && continue

      # Находим виджет по провайдеру на конкретном экране
      sid=$(sqlite3 "$DB" "SELECT _id FROM favorites WHERE itemType=4 AND appWidgetProvider='$w_provider' LIMIT 1;")

      if [ -n "$sid" ]; then
        sqlite3 "$DB" "
          UPDATE favorites
          SET
            screen=$w_screen,
            cellX=$((w_cellX - 1)),
            cellY=$((w_cellY - 1)),
            spanX=$w_spanX,
            spanY=$w_spanY
          WHERE _id=$sid;
          "
        echo "    -> Restored Widget: $w_provider (ID: $sid) to $w_spanX x $w_spanY"
      else
        echo "    [!] Warning: Widget $w_provider not found in DB, skipping."
      fi
    done <"$LAYOUT3"
  done

  ########################################
  # Verify database
  ########################################

  echo "[+] Verifying database..."

  result=$(sqlite3 "$DB" "PRAGMA integrity_check;")

  [ "$result" = "ok" ] || {
    echo "ERROR: integrity_check failed"
    exit 1
  }

  echo "[+] integrity_check OK"
  echo "[+] Done"

done

########################################
# Reboot Launcher MIUI
########################################
/system/bin/am force-stop com.miui.home
