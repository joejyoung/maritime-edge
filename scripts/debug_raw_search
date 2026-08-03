debug_raw_search() {
	echo "Searching in: $(realpath ../capture)"
	echo "------------------------------------"

	count = 0

	find ../capture -type f -name "*.raw" | while read -r f; do
		echo "FOUND: $f"
		count=$((count+1))
	done

	if [ "$count" -eq 0 ]; then
		echo "No .raw files found!"
	fi
}
