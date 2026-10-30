#!/bin/bash
for p in $(pgrep -f "yb-(master|tserver) .*127\.0\.0\.77"); do kill $p; done
sleep 5
pgrep -af "yb-(master|tserver) .*127\.0\.0\.77" || echo stopped
