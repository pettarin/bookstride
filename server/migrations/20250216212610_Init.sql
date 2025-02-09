CREATE TABLE track(isbn INTEGER, bearer TEXT, track INTEGER, datetime INTEGER, file_id INTEGER NOT NULL, ready BOOLEAN NOT NULL, PRIMARY KEY (isbn, bearer, track));
CREATE INDEX tracks ON track(isbn, bearer);
CREATE TABLE download(isbn INTEGER NOT NULL, bearer TEXT NOT NULL, datetime INTEGER NOT NULL, path TEXT NOT NULL, PRIMARY KEY(isbn, bearer, datetime));
