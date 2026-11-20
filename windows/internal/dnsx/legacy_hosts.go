package dnsx

import (
	"bytes"
	"errors"
	"strings"
)

const recoveryStart = "# BEGIN NIMB GEOHIDE RECOVERY"
const recoveryEnd = "# END NIMB GEOHIDE RECOVERY"

func hasLegacyHosts(data []byte) bool {
	return bytes.Contains(data, []byte(recoveryStart)) || bytes.Contains(data, []byte(recoveryEnd))
}

// stripLegacyHosts removes the retired GeoHide block and preserves every byte outside it.
func stripLegacyHosts(data []byte) ([]byte, error) {
	if !hasLegacyHosts(data) {
		return data, nil
	}
	if bytes.IndexByte(data, 0) >= 0 {
		return nil, errors.New("формат файла hosts не поддерживается")
	}
	const bom = "\xef\xbb\xbf"
	body := string(data)
	prefix := ""
	if strings.HasPrefix(body, bom) {
		prefix, body = bom, strings.TrimPrefix(body, bom)
	}
	if strings.Count(body, recoveryStart) != 1 || strings.Count(body, recoveryEnd) != 1 {
		return nil, errors.New("некорректный блок GeoHide в hosts")
	}
	lines := strings.SplitAfter(body, "\n")
	start, end := -1, -1
	for i, line := range lines {
		switch strings.TrimRight(line, "\r\n") {
		case recoveryStart:
			start = i
		case recoveryEnd:
			end = i
		}
	}
	if start < 0 || start >= end || !strings.HasSuffix(lines[end], "\n") {
		return nil, errors.New("некорректный блок GeoHide в hosts")
	}
	return []byte(prefix + strings.Join(lines[:start], "") + strings.Join(lines[end+1:], "")), nil
}
