unique_from_last() {
  # Function to make a list unique from the last occurrence
  # Accept a single space-separated string as input
  local input_string="$1"
  local seen_l=""           # Tracking seen items for -l strings
  local seen_L=""           # Tracking seen items for -L strings
  local l_list=()           # Array for -l strings
  local L_list=()           # Array for -L strings
  local others=()           # Array for other strings

  # Convert the input string into an array
  IFS=' ' read -r -a list <<< "$input_string"

  # Traverse the list from first to last
  for item in "${list[@]}"; do
    if [[ "$item" == -L* || "$item" == -I* ]]; then
      # -L strings processed from first to last occurrence
      if [[ ! " $seen_L " =~ " $item " ]]; then
        L_list+=("$item")
        seen_L="$seen_L $item"
      fi
    elif [[ "$item" == -l* ]]; then
      # -l strings processed from last to first occurrence
      if [[ ! " $seen_l " =~ " $item " ]]; then
        l_list=("$item" "${l_list[@]}")
        seen_l="$seen_l $item"
      fi
    else
      # Other strings are appended in order of appearance
      others+=("$item")
    fi
  done

  # Assemble the final result: -L first -> others -> -l last
  local result="${L_list[*]} ${others[*]} ${l_list[*]}"

  # Trim and print result
  echo "${result% }"
}

replace_l_flags() {
  # Function to replace -lxxx with a specific path/xxx.lib
  local input_string="$1"  # Get the input string containing linker flags

  # Initialize an empty result
  local result=""

  # Convert the input string into an array of words
  IFS=' ' read -r -a flags <<< "$input_string"

  # Process each "flag" in the input string
  for flag in "${flags[@]}"; do
    if [[ "$flag" == -l* ]] && ! [[ " ${system_libs_exclude[*]} " =~ " ${flag#-l} " ]]; then
      # Replace -lxxx with path/xxx.lib
      local lib_name="${flag#-l}"
      if [[ -f "$host_conda_libs/$lib_name.lib" ]]; then
        result+="$host_conda_libs/$lib_name.lib "
      else
        result+="$build_conda_libs/$lib_name.lib "
      fi
    else
      # Keep everything else (unchanged flags)
      result+="$flag "
    fi
  done

  # Return the modified string (trimmed)
  echo "${result% }"
}

replace_l_flag_in_file() {
  local file="$1"
  local debug="${2:-false}" # Enables debug if DEBUG is set to 'true'

  if [[ -f "$file" ]]; then
    $debug && echo "Processing file: $file"

    # Temporary file for processing
    tmpfile=$(mktemp) || { echo "Error: Failed to create temp file" >&2; exit 1; }
    $debug && echo "  Created temp file: $tmpfile"

    while IFS= read -r line; do
      if [[ "$line" =~ ^[GIL][[:alnum:]_]*IBS ]]; then
        $debug && echo "  Processing matching line (G*, L*, or I*IBS): $line"
        updated_line=""

        for word in $line; do
          if [[ $word == -l* ]]; then
            flag_name=$(echo "$word" | sed -E 's/(-l[[:alnum:]_\-\.]+)/\1/')
            lib_name=$(echo "$word" | sed -E 's/-l([[:alnum:]_\-\.]+)/\1/')
            escaped_flag_name=$(echo "$flag_name" | sed -E 's/[-\.]/\\&/g')

            $debug && echo "    Found linker flag: $flag_name (library: $lib_name)"

            if [[ $lib_name =~ ^($exclude_regex)$ ]]; then
              $debug && echo "      Library '$lib_name' is excluded. Keeping unchanged."
              updated_line+="$word "
            else
              # Verify if the library file exists before replacing
              if [[ -f "$build_conda_libs/${lib_name}.lib" ]]; then
                $debug && echo "      Found in build_conda_libs: $build_conda_libs/${lib_name}.lib"
                updated_line+=$(echo "$word" | sed -E "s|${escaped_flag_name}|$build_conda_libs/${lib_name}.lib|")
                updated_line+=" "
              elif [[ -f "$host_conda_libs/${lib_name}.lib" ]]; then
                $debug && echo "      Found in host_conda_libs: $host_conda_libs/${lib_name}.lib"
                updated_line+=$(echo "$word" | sed -E "s|${escaped_flag_name}|$host_conda_libs/${lib_name}.lib|")
                updated_line+=" "
              else
                $debug && echo "      Warning: Library file not found for '$lib_name'. Keeping unchanged."
                updated_line+="$word "
              fi
            fi
          else
            updated_line+="$word "
          fi
        done

        $debug && echo "    Updated line: $updated_line"
        echo "$updated_line" >> "$tmpfile"
      else
        # $debug && echo "  Non-matching line: $line"
        echo "$line" >> "$tmpfile"
      fi
    done < "$file"

    # Overwrite the original file with the updated content
    mv "$tmpfile" "$file" || { echo "Error: Failed to replace original file $file with $tmpfile" >&2; exit 1; }
    chmod +x "$file"
    $debug && echo "  Successfully updated file: $file"
  else
    $debug && echo "Error: File $file does not exist"
  fi
}

replace_l_flag_in_files() {
  local files=("$@")
  for file in "${files[@]}"; do
    echo "   Updating: $file"
    replace_l_flag_in_file "$file"
  done
}
