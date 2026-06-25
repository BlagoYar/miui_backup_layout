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
EXPORT_ROOT="$SCRIPT_DIR/export"

if ! command -v sqlite3 >/dev/null 2>&1; then
	echo
	echo "[!] sqlite3 not found"
	read -rp "Install sqlite3 now? [Y/n]: " answer
	answer=${answer:-Y}

	case "$answer" in
	Y | y)
		set +e
		pkg install -y sqlite
		set -e
		if ! command -v sqlite3 >/dev/null 2>&1; then
			echo "[!] sqlite3 is still unavailable."
			exit 1
		fi
		;;
	*) exit 1 ;;
	esac
fi

mapfile -t DBS < <(find "$DB_DIR" -maxdepth 1 -type f -name 'launcher*.db' | sed 's#^.*/##' | sort)
count=${#DBS[@]}

[ "$count" -gt 0 ] || {
	echo "ERROR: launcher databases not found"
	exit 1
}

if [ "$count" -eq 1 ]; then
	DB="$DB_DIR/${DBS[0]}"
	EXPORT_DIR="$SCRIPT_DIR/export/$(basename "${DBS[0]%.*}")"
	SELECTED_DBS=("$DB")
else
	echo
	echo "Found launcher databases:"
	echo "0) All"
	i=1
	for db in "${DBS[@]}"; do
		echo "$i) $db"
		i=$((i + 1))
	done
	echo
	read -rp "Select database(s) to export [0]: " choice
	choice=${choice:-0}

	SELECTED_DBS=()
	if [ "$choice" = "0" ]; then
		for db in "${DBS[@]}"; do SELECTED_DBS+=("$DB_DIR/$db"); done
	else
		IFS=',' read -ra NUMS <<<"$choice"
		for n in "${NUMS[@]}"; do
			n=$(echo "$n" | tr -d ' ')
			[ "$n" -ge 1 ] 2>/dev/null || continue
			[ "$n" -le "$count" ] 2>/dev/null || continue
			idx=$((n - 1))
			SELECTED_DBS+=("$DB_DIR/${DBS[$idx]}")
		done
		[ "${#SELECTED_DBS[@]}" -gt 0 ] || {
			echo "ERROR: invalid selection"
			exit 1
		}
	fi
fi

for DB in "${SELECTED_DBS[@]}"; do
	db_name=$(basename "$DB")
	db_basename="${db_name%.*}"

	echo
	echo "========================================"
	echo "[+] Exporting: $db_name"
	echo "========================================"
	echo

	BASE_OUT="$EXPORT_ROOT/$db_basename"
	mkdir -p "$BASE_OUT"

	# --- 1. Export Desktops ---
	mkdir -p "$BASE_OUT/desktops"
	rm -f "$BASE_OUT/desktops/layout.txt"

	for screen in $(sqlite3 "$DB" "SELECT DISTINCT screen FROM favorites WHERE container=-100 ORDER BY screen;"); do
		{
			echo "SCREEN $screen"
			echo
			sqlite3 "$DB" "
      SELECT
      title || '|' || IFNULL(profileId, 0) || '|' ||
      CASE WHEN intent IS NULL THEN 'NONE' ELSE UPPER(hex(intent)) END || '|' ||
      (cellX+1) || '|' || (cellY+1)
      FROM favorites WHERE container=-100 AND screen=$screen AND itemType!=4 AND title IS NOT NULL AND title!='' ORDER BY cellY,cellX;"
			echo
		} >>"$BASE_OUT/desktops/layout.txt"
	done
	echo "[+] Exported Desktops"

	# --- 2. Export Widgets ---
	mkdir -p "$BASE_OUT/widgets"
	sqlite3 "$DB" "
  SELECT 'WIDGET|' || screen || '|' || (cellX+1) || '|' || (cellY+1) || '|' || spanX || '|' || spanY || '|' || appWidgetProvider
  FROM favorites WHERE itemType=4 ORDER BY screen,cellY,cellX;" >"$BASE_OUT/widgets/layout.txt"
	echo "[+] Exported Widgets"

	# --- 3. Export Dock ---
	mkdir -p "$BASE_OUT/dock"
	sqlite3 "$DB" "
  SELECT 'DOCK|' || (cellX+1) || '|' || (cellY+1) || '|' || title || '|' || IFNULL(profileId, 0) || '|' ||
  CASE WHEN intent IS NULL THEN 'NONE' ELSE UPPER(hex(intent)) END
  FROM favorites WHERE container=-101 ORDER BY cellX,cellY;" >"$BASE_OUT/dock/layout.txt"
	echo "[+] Exported Dock"

	# --- 4. Export Folders (Без казино) ---
	echo "[+] Exporting Folders..."

	total_folders=$(sqlite3 "$DB" "SELECT count(*) FROM favorites WHERE itemType=2;")
	curr_f=0

	sqlite3 -separator '|' "$DB" "SELECT _id,title,screen,cellX,cellY FROM favorites WHERE itemType=2 ORDER BY title,_id;" | while IFS= read -r folder; do
		[ -z "$folder" ] && continue
		IFS='|' read -r folder_id folder_name screen cellX cellY <<<"$folder"
		[ -z "$folder_name" ] && continue

		fs_folder_name=$(echo "$folder_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '/\\:*?"<>|' '_' | sed 's/[[:space:]]\+/_/g' | sed 's/__*/_/g')

		EXPORT_DIR="$BASE_OUT/folders/${fs_folder_name}_${folder_id}"
		mkdir -p "$EXPORT_DIR"
		LAYOUT="$EXPORT_DIR/layout.txt"

		{
			echo "FOLDER $folder_name"
			echo "SCREEN $screen"
			echo "CELLX $((cellX + 1))"
			echo "CELLY $((cellY + 1))"
			echo
			sqlite3 "$DB" "
      SELECT IFNULL(title, 'Unknown') || '|' || IFNULL(profileId, 0) || '|' ||
      CASE WHEN intent IS NULL THEN 'NONE' ELSE UPPER(hex(intent)) END || '|' ||
      (IFNULL(cellX, 0)+1) || '|' || (IFNULL(cellY, 0)+1)
      FROM favorites WHERE container=$folder_id ORDER BY cellY, cellX;"
		} >"$LAYOUT"

		curr_f=$((curr_f + 1))
		printf "\r\033[2K    -> Exported [%d/%d]: %s" "$curr_f" "$total_folders" "${folder_name:0:40}"
	done
	echo # Перенос строки после завершения
done

echo
echo "[+] All exports completed successfully."
exit 0
