#!/bin/bash
failed_images=()
success_count=0
total_count=0

while IFS= read -r image; do
  # Skip empty lines
  [[ -z "$image" ]] && continue

  ((total_count++))
  echo "Checking [$total_count]: $image"

  if skopeo inspect --no-tags --retry-times 2 "docker://$image" > /dev/null 2>&1; then
    ((success_count++))
  else
    failed_images+=("$image")
    echo "  ❌ FAILED"
  fi
done < images/images-full.txt

echo ""
echo "========================================="
echo "Summary:"
echo "  Total images: $total_count"
echo "  Successful: $success_count"
echo "  Failed: ${#failed_images[@]}"
echo "========================================="

if [ ${#failed_images[@]} -gt 0 ]; then
  echo ""
  echo "Failed images:"
  for img in "${failed_images[@]}"; do
    echo "  - $img"
  done
  exit 1
fi
