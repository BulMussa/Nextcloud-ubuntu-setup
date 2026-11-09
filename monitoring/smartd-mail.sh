#!/usr/bin/env bash
# Called by smartd (-M exec) to send a disk warning through send-alert.sh.
exec /usr/local/bin/send-alert.sh "$SMARTD_SUBJECT" "$SMARTD_FULLMESSAGE"
