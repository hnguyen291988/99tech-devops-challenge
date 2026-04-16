# Problem 1 — Too Many Things To Do

## Objective

Filter transaction-log.txt for orders that are:
- Symbol: TSLA
- Side: sell

Then submit a GET https://example.com/api/:order_id for each matching order, writing all responses to ./output.txt.

---

## Solution

```bash
jq -r 'select(.symbol == "TSLA" and .side == "sell") | .order_id' transaction-log.txt \
  | xargs -I{} curl -s "https://example.com/api/{}" >> ./output.txt
```

---

## How It Works

| Part | Purpose |
|---|---|
| jq -r 'select(...)' | Parses each JSON line, filters where symbol == "TSLA" AND side == "sell", outputs only the order_id value as plain text |
| xargs -I{} | Takes each order_id on stdin and substitutes it into the command as {} |
| curl -s "https://example.com/api/{}" | Makes a silent GET request to the API endpoint with the order ID |
| >> ./output.txt | Appends each API response to the output file (using >> not > so responses accumulate) |

---

## Matching Orders

From the provided log, two orders match (TSLA + sell):

| order_id | symbol | side | price | timestamp |
|---|---|---|---|---|
| 12346 | TSLA | sell | 890.15 | 2025-02-18T09:16:10Z |
| 12362 | TSLA | sell | 885.10 | 2025-02-18T09:28:50Z |

These will generate two GET requests:
```
GET https://example.com/api/12346
GET https://example.com/api/12362
```

---

## Notes & Considerations

- **jq availability:** jq is available in Ubuntu 24.04 default apt repos (apt install jq). If unavailable, a grep + awk fallback is:
  ```bash
  grep '"symbol": "TSLA"' transaction-log.txt \
    | grep '"side": "sell"' \
    | grep -o '"order_id": "[^"]*"' \
    | awk -F'"' '{print $4}' \
    | xargs -I{} curl -s "https://example.com/api/{}" >> ./output.txt
  ```
- **Parallel execution:** For large log files, replace xargs with xargs -P 10 to run up to 10 concurrent requests.
- **Error handling:** To capture HTTP errors, add -f flag to curl or pipe through tee to log failures separately.
