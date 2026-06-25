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

mapfile -t EXPORTS < <(find "$SCRIPT_DIR/export" -mindepth 1 -maxdepth 1 -type d | sort)
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

mapfile -t FOLDER_LAYOUTS < <(find "$EXPORT_DIR/folders" -type f -name 'layout.txt' 2>/dev/null | sort)
mapfile -t DESKTOP_LAYOUTS < <(find "$EXPORT_DIR/desktops" -type f -name 'layout.txt' 2>/dev/null | sort)
mapfile -t WIDGET_LAYOUTS < <(find "$EXPORT_DIR/widgets" -type f -name 'layout.txt' 2>/dev/null | sort)
mapfile -t DOCK_LAYOUTS < <(find "$EXPORT_DIR/dock" -type f -name 'layout.txt' 2>/dev/null | sort)

echo "FOLDERS=${#FOLDER_LAYOUTS[@]}"
echo "DESKTOPS=${#DESKTOP_LAYOUTS[@]}"
echo "WIDGETS=${#WIDGET_LAYOUTS[@]}"
echo "DOCK=${#DOCK_LAYOUTS[@]}"

[ "${#FOLDER_LAYOUTS[@]}" -gt 0 ] || {
	echo "ERROR: no folder layouts found"
	exit 1
}

########################################
# DB loop
########################################
TARGET_DB_NAME="$(basename "$EXPORT_DIR").db"
TARGET_DB_PATH="$DB_DIR/$TARGET_DB_NAME"

if [ ! -f "$TARGET_DB_PATH" ]; then
	echo "ERROR: Target database $TARGET_DB_NAME not found in $DB_DIR"
	exit 1
fi

SELECTED_DBS=("$TARGET_DB_PATH")
echo "TARGET DB=[$TARGET_DB_NAME]"

for DB in "${SELECTED_DBS[@]}"; do
	echo
	echo "========================================"
	echo "[+] Processing: $(basename "$DB")"
	echo "========================================"
	echo

	backup="${DB}.$(date +%d-%m-%Y_%H-%M-%S).bak"
	cp -a "$DB" "$backup"
	echo "[+] Backup created"
	echo

	for LAYOUT in "${FOLDER_LAYOUTS[@]}"; do

		if grep -q '^FOLDER ' "$LAYOUT"; then
			LAYOUT_TYPE="folder"
		else
			LAYOUT_TYPE="desktop"
		fi

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

		shortcut_count=$(grep -Ev '^(FOLDER|SCREEN|CELLX|CELLY) ' "$LAYOUT" | grep -c '^[^[:space:]]')

		[ "$shortcut_count" -gt 0 ] || {
			echo "ERROR: no shortcuts in layout"
			exit 1
		}

		# Вертификация
		missing=0
		declare -A ID_MAP

		while IFS='|' read -r col1 col2 col3 col4 col5; do
			[ -z "$col1" ] && continue

			if [ -n "$col5" ]; then
				title="$col1"
				profile_id="$col2"
				hex_intent="$col3"

				profile_cond="AND IFNULL(profileId, 0)=$profile_id"
				if [ "$hex_intent" = "NONE" ]; then
					intent_cond="AND intent IS NULL"
				else
					intent_cond="AND UPPER(hex(intent))='$hex_intent'"
				fi
			else
				title="$col1"
				profile_id="0"
				hex_intent="NONE"
				profile_cond=""
				intent_cond=""
			fi

			safe_title=$(sql_escape "$title")
			sids=$(sqlite3 "$DB" "SELECT _id FROM favorites WHERE title='$safe_title' $profile_cond $intent_cond;")
			count=$(echo "$sids" | awk 'NF{c++} END{print c+0}')

			if [ "$count" -gt 1 ]; then
				sid=$(echo "$sids" | head -n 1)
			elif [ -z "$sids" ]; then
				echo "[!] Missing in DB: $title"
				missing=$((missing + 1))
				continue
			else
				sid="$sids"
			fi

			key=$(printf '%s\037%s\037%s' "$title" "$profile_id" "$hex_intent")
			if [[ -v ID_MAP["$key"] ]]; then continue; fi
			ID_MAP["$key"]="$sid"

		done < <(grep -Ev '^(FOLDER|SCREEN|CELLX|CELLY) ' "$LAYOUT" | grep -v '^[[:space:]]*$')

		[ "$missing" -eq 0 ] || {
			echo "[!] Aborting folder: $folder_name"
			continue
		}

		# Ищем/создаем папку
		folder_id=$(sqlite3 "$DB" "SELECT _id FROM favorites WHERE title='$safe_folder_name' AND itemType=2 LIMIT 1;")

		if [ -z "$folder_id" ]; then
			next_id=$(sqlite3 "$DB" "SELECT IFNULL(MAX(_id),0)+1 FROM favorites;")
			sqlite3 "$DB" "
          INSERT INTO favorites (_id, title, container, screen, cellX, cellY, spanX, spanY, itemType, appWidgetId, itemFlags, profileId, originWidgetId)
          VALUES ($next_id, '$safe_folder_name', -100, $desktop_screen, $db_cellX, $db_cellY, 1, 1, 2, -1, 0, 0, -1);"
			folder_id=$next_id
			echo "[+] Folder: $folder_name (Created ID: $folder_id)"
		else
			sqlite3 "$DB" "UPDATE favorites SET screen=$desktop_screen, cellX=$db_cellX, cellY=$db_cellY WHERE _id=$folder_id;"
			echo "[+] Folder: $folder_name (Found ID: $folder_id)"
		fi

		# Восстанавливаем иконки (Без казино)
		curr_item=0
		while IFS='|' read -r col1 col2 col3 col4 col5; do
			[ -z "$col1" ] && continue

			if [ -n "$col5" ]; then
				title="$col1"
				profile_id="$col2"
				hex_intent="$col3"
				db_shortcut_cellX=$((col4 - 1))
				db_shortcut_cellY=$((col5 - 1))
			else
				title="$col1"
				profile_id="0"
				hex_intent="NONE"
				db_shortcut_cellX=$col2
				db_shortcut_cellY=$col3
			fi

			key=$(printf '%s\037%s\037%s' "$title" "$profile_id" "$hex_intent")
			shortcut_id="${ID_MAP["$key"]}"

			curr_item=$((curr_item + 1))

			if [ -n "$shortcut_id" ]; then
				sqlite3 "$DB" "UPDATE favorites SET container=$folder_id, screen=-1, cellX=$db_shortcut_cellX, cellY=$db_shortcut_cellY WHERE _id=$shortcut_id;"
				# Красивый вывод с перезаписью строки
				printf "\r\033[2K    -> [%d/%d] %s" "$curr_item" "$shortcut_count" "${title:0:40}"
			else
				echo -e "\n    [!] Warning: Could not find ID for $title in map"
			fi

		done < <(grep -Ev '^(FOLDER|SCREEN|CELLX|CELLY) ' "$LAYOUT" | grep -v '^[[:space:]]*$')
		echo # Перенос строки после завершения папки
	done

	# Восстанавливаем рабочие столы (Без казино)
	echo "[+] Restoring Desktops..."
	for LAYOUT2 in "${DESKTOP_LAYOUTS[@]}"; do
		desktop_screen=""
		total_d=$(grep -c '|' "$LAYOUT2" || true)
		curr_d=0

		while IFS= read -r line; do
			[ -z "$line" ] && continue

			if [[ "$line" == SCREEN\ * ]]; then
				desktop_screen=$(echo "$line" | awk '{print $2}')
				continue
			fi

			IFS='|' read -r title profile_id hex_intent cellX cellY <<<"$line"
			[ -z "$title" ] && continue
			safe_title=$(sql_escape "$title")

			profile_cond="AND IFNULL(profileId, 0)=$profile_id"
			if [ "$hex_intent" = "NONE" ]; then
				intent_cond="AND intent IS NULL"
			else
				intent_cond="AND UPPER(hex(intent))='$hex_intent'"
			fi

			sid=$(sqlite3 "$DB" "SELECT _id FROM favorites WHERE title='$safe_title' $profile_cond $intent_cond LIMIT 1;")
			[ -n "$sid" ] || continue

			db_shortcut_cellX=$((cellX - 1))
			db_shortcut_cellY=$((cellY - 1))

			sqlite3 "$DB" "UPDATE favorites SET container=-100, screen=$desktop_screen, cellX=$db_shortcut_cellX, cellY=$db_shortcut_cellY WHERE _id=$sid;"

			curr_d=$((curr_d + 1))
			printf "\r\033[2K    -> Desktop Item [%d/%d]: %s" "$curr_d" "$total_d" "${title:0:40}"
		done <"$LAYOUT2"
		[ "$total_d" -gt 0 ] && echo
	done

	# Восстанавливаем док (Без казино)
	echo "[+] Restoring Dock..."
	for LAYOUT_DOCK in "${DOCK_LAYOUTS[@]}"; do
		total_dock=$(grep -c 'DOCK|' "$LAYOUT_DOCK" || true)
		curr_dock=0

		while IFS='|' read -r d_type d_cellX d_cellY d_title d_profile_id d_hex_intent; do
			[ "$d_type" != "DOCK" ] && continue

			safe_d_title=$(sql_escape "$d_title")

			profile_cond="AND IFNULL(profileId, 0)=$d_profile_id"
			if [ "$d_hex_intent" = "NONE" ]; then
				intent_cond="AND intent IS NULL"
			else
				intent_cond="AND UPPER(hex(intent))='$d_hex_intent'"
			fi

			sid=$(sqlite3 "$DB" "SELECT _id FROM favorites WHERE title='$safe_d_title' $profile_cond $intent_cond LIMIT 1;")

			curr_dock=$((curr_dock + 1))

			if [ -n "$sid" ]; then
				sqlite3 "$DB" "UPDATE favorites SET container=-101, cellX=$((d_cellX - 1)), cellY=$((d_cellY - 1)) WHERE _id=$sid;"
				printf "\r\033[2K    -> Dock [%d/%d]: %s" "$curr_dock" "$total_dock" "${d_title:0:40}"
			else
				echo -e "\n    [!] Warning: Dock item $d_title not found in DB"
			fi
		done <"$LAYOUT_DOCK"
		[ "$total_dock" -gt 0 ] && echo
	done

	# Восстанавливаем виджеты (Без казино)
	echo "[+] Restoring Widgets..."
	for LAYOUT3 in "${WIDGET_LAYOUTS[@]}"; do
		total_w=$(grep -c 'WIDGET|' "$LAYOUT3" || true)
		curr_w=0

		while IFS='|' read -r w_type w_screen w_cellX w_cellY w_spanX w_spanY w_provider; do
			[ "$w_type" != "WIDGET" ] && continue

			sid=$(sqlite3 "$DB" "SELECT _id FROM favorites WHERE itemType=4 AND appWidgetProvider='$w_provider' LIMIT 1;")

			curr_w=$((curr_w + 1))
			short_prov=$(echo "$w_provider" | awk -F'.' '{print $NF}') # берем только конец названия для красоты

			if [ -n "$sid" ]; then
				sqlite3 "$DB" "UPDATE favorites SET screen=$w_screen, cellX=$((w_cellX - 1)), cellY=$((w_cellY - 1)), spanX=$w_spanX, spanY=$w_spanY WHERE _id=$sid;"
				printf "\r\033[2K    -> Widget [%d/%d]: %s" "$curr_w" "$total_w" "${short_prov:0:40}"
			else
				echo -e "\n    [!] Warning: Widget $short_prov not found in DB"
			fi
		done <"$LAYOUT3"
		[ "$total_w" -gt 0 ] && echo
	done

	echo "[+] Verifying database..."
	result=$(sqlite3 "$DB" "PRAGMA integrity_check;")
	[ "$result" = "ok" ] || {
		echo "ERROR: integrity_check failed"
		exit 1
	}
	echo "[+] DB OK. Done."

done

########################################
# Reboot Launcher
########################################
/system/bin/am force-stop com.miui.home
