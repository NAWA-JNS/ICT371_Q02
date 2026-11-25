-- ICT371 Advanced Database | Question 2: University Fee Payments
-- Name: Nawa Sumbwanyambe | Student number: 202308788
-- DBMS: PostgreSQL (PL/pgSQL; scheduling with the pg_cron extension)

DROP TABLE IF EXISTS daily_collections, payment_audit, payments, students CASCADE;

-- ==== (a) Database: create the tables and constraints
CREATE TABLE students (
    student_id     SERIAL        PRIMARY KEY,
    student_number VARCHAR(20)   NOT NULL UNIQUE,
    full_name      VARCHAR(100)  NOT NULL,
    fee_due        NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id SERIAL        PRIMARY KEY,
    student_id INTEGER       NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on    DATE          NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE payment_audit (
    audit_id   SERIAL        PRIMARY KEY,
    payment_id INTEGER       NOT NULL REFERENCES payments(payment_id),
    student_id INTEGER       NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL,
    logged_at  TIMESTAMP     NOT NULL DEFAULT now()
);

CREATE TABLE daily_collections (
    collection_date DATE          PRIMARY KEY,
    payment_count   INTEGER       NOT NULL,
    total_amount    NUMERIC(12,2) NOT NULL
);

-- ==== (b) Function fn_fee_balance
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_fee  NUMERIC(12,2);
    v_paid NUMERIC(12,2);
BEGIN
    SELECT fee_due INTO v_fee FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    SELECT COALESCE(SUM(amount), 0) INTO v_paid      -- COALESCE: no payments => 0 paid
    FROM payments
    WHERE student_id = p_student_id;

    RETURN v_fee - v_paid;
END;
$$;

-- ==== (c) Procedure pr_receive_payment (does NOT write the audit row; the trigger does)
CREATE OR REPLACE PROCEDURE pr_receive_payment(p_student_id INTEGER, p_amount NUMERIC, p_paid_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_balance NUMERIC(12,2);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Invalid payment amount: % (must be greater than zero)', p_amount;
    END IF;

    -- Lock the student row so two simultaneous payments cannot together overpay.
    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    v_balance := fn_fee_balance(p_student_id);
    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment % exceeds outstanding balance % for student %',
            p_amount, v_balance, p_student_id;
    END IF;

    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, COALESCE(p_paid_on, CURRENT_DATE));   -- fee_due untouched
END;
$$;

-- ==== (d) Trigger: AFTER INSERT row trigger on payments
CREATE OR REPLACE FUNCTION trg_fn_payments_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, now());
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_payments_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_payments_audit();

-- ==== (e) View v_fee_balances (settled students excluded)
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number,
       s.full_name,
       s.fee_due - COALESCE(SUM(p.amount), 0) AS outstanding_balance
FROM students s
LEFT JOIN payments p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING s.fee_due - COALESCE(SUM(p.amount), 0) > 0;

-- ==== (f) Composite index: student_id (equality) then paid_on (range)
CREATE INDEX idx_payments_student_paid_on ON payments (student_id, paid_on);

-- ==== (g) Scheduled job: pr_refresh_collections
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day is required';
    END IF;

    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0)
    FROM payments
    WHERE paid_on = p_day
    ON CONFLICT (collection_date) DO UPDATE          -- replace an existing summary row
    SET payment_count = EXCLUDED.payment_count,
        total_amount  = EXCLUDED.total_amount;
END;
$$;

-- Requires: CREATE EXTENSION pg_cron;
SELECT cron.schedule(
    'refresh_collections_daily',
    '0 1 * * *',                                         -- every day at 01:00
    $$CALL pr_refresh_collections(CURRENT_DATE - 1)$$    -- previous day
);

-- ==== (a) Seed data: 3 students with different balances; 6 payments; student 3 has none
INSERT INTO students (student_number, full_name, fee_due) VALUES
    ('202300001', 'Alice Banda',  5000.00),
    ('202300002', 'Brian Phiri',  3000.00),
    ('202300003', 'Chola Mwansa', 4000.00);

CALL pr_receive_payment(1, 1000, '2026-11-20');
CALL pr_receive_payment(1, 1500, '2026-11-21');
CALL pr_receive_payment(1,  500, '2026-11-24');
CALL pr_receive_payment(2, 1200, '2026-11-21');
CALL pr_receive_payment(2, 1000, '2026-11-24');
CALL pr_receive_payment(2,  800, '2026-11-24');   -- Brian is now fully settled

SELECT * FROM students ORDER BY student_id;
SELECT * FROM payments ORDER BY payment_id;

-- ==== (b) Function tests
SELECT student_id, fn_fee_balance(student_id) AS balance FROM students ORDER BY student_id;
DO $$ BEGIN PERFORM fn_fee_balance(99); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;

-- ==== (c) Procedure tests: invalid payments rejected
DO $$ BEGIN CALL pr_receive_payment(1, NULL, '2026-11-25'); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_payment(1, 0,    '2026-11-25'); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_payment(1, -50,  '2026-11-25'); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_payment(1, 2500, '2026-11-25'); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;  -- balance is 2000
DO $$ BEGIN CALL pr_receive_payment(99, 10,  '2026-11-25'); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;
CALL pr_receive_payment(3, 1000, '2026-11-25');                 -- first payment for Chola
SELECT student_id, fee_due FROM students ORDER BY student_id;   -- fee_due unchanged

-- ==== (d) Trigger test: every payment (6 + 1) has exactly one audit row
SELECT a.audit_id, a.payment_id, a.student_id, a.amount, a.logged_at IS NOT NULL AS has_timestamp
FROM payment_audit a ORDER BY a.audit_id;
SELECT (SELECT COUNT(*) FROM payments) AS payments, (SELECT COUNT(*) FROM payment_audit) AS audit_rows;

-- ==== (e) View: Brian (settled) is excluded
SELECT * FROM v_fee_balances ORDER BY student_number;

-- ==== (f) EXPLAIN for the matching query
ANALYZE payments;
SET enable_seqscan = off;   -- tiny demo table: force the planner to show the index plan
EXPLAIN
SELECT payment_id, amount, paid_on
FROM payments
WHERE student_id = 1
  AND paid_on BETWEEN '2026-11-20' AND '2026-11-24';
RESET enable_seqscan;

-- ==== (g) Run the job, rerun it: summary row is replaced
CALL pr_refresh_collections('2026-11-24');
SELECT * FROM daily_collections ORDER BY collection_date;
INSERT INTO payments (student_id, amount, paid_on) VALUES (1, 100, '2026-11-24');  -- late payment arrives
CALL pr_refresh_collections('2026-11-24');                                         -- rerun replaces the row
SELECT * FROM daily_collections ORDER BY collection_date;
SELECT jobname, schedule, command FROM cron.job WHERE jobname = 'refresh_collections_daily';
