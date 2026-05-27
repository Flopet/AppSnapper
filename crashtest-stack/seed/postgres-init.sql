CREATE TABLE IF NOT EXISTS widgets (id SERIAL PRIMARY KEY, name TEXT, qty INT);
INSERT INTO widgets (name, qty) VALUES ('alpha', 10), ('bravo', 20), ('charlie', 30);
