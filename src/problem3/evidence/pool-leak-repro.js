// Reproduces the client leak in the /api/users handler.
// Same connect -> query -> release sequence as src/problem3/api/src/index.js,
// but with max:2 so exhaustion happens in 2 requests instead of 10.
const { Pool } = require("pg");

const pool = new Pool({
  host: process.env.DB_HOST, user: "postgres", password: "postgres",
  database: "postgres", port: 5432, max: 2,
});

// A query that fails at execution time, with the client already checked out.
// Stands in for any real failure: statement timeout, deadlock, failover mid-query.
const FAILING = "SELECT 1/0";

async function handler(n) {
  try {
    const db = await pool.connect();
    const r = await db.query(FAILING);   // throws
    db.release();                        // never reached
    return `req ${n}: ok`;
  } catch (err) {
    return `req ${n}: 500 ${err.message}`;
  }
}

(async () => {
  for (const n of [1, 2]) {
    console.log(await handler(n));
    console.log(`   pool: total=${pool.totalCount} idle=${pool.idleCount} waiting=${pool.waitingCount}`);
  }

  console.log("req 3: calling pool.connect() ...");
  const timer = setTimeout(() => {
    console.log("req 3: STILL WAITING after 5s -- pool exhausted, no timeout configured.");
    console.log(`   pool: total=${pool.totalCount} idle=${pool.idleCount} waiting=${pool.waitingCount}`);
    console.log("   In the real app this is a hung request: nginx eventually 504s and the API never recovers.");
    process.exit(0);
  }, 5000);
  await pool.connect();
  clearTimeout(timer);
  console.log("req 3: got a client (no leak)");
  process.exit(0);
})();
