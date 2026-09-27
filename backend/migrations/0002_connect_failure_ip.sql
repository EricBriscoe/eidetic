-- Rate-limit wrong connect codes per client IP, so a stranger guessing can't
-- lock the owner out; the global cap stays only as a backstop.
ALTER TABLE connect_failures ADD COLUMN ip TEXT;
CREATE INDEX connect_failures_ip ON connect_failures(ip, at);
