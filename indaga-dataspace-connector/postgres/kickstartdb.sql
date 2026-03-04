--Firefy Project
-- CREATE DATABASE IF NOT EXISTS indaga;
SELECT 'CREATE DATABASE indaga' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'indaga')\gexec
\c indaga;

CREATE SCHEMA IF NOT EXISTS oauth;
CREATE SCHEMA IF NOT EXISTS connector;

CREATE EXTENSION IF NOT EXISTS postgis;

-- *************************************************************************
-- ** First & Last functions creation
-- *************************************************************************
-- Create a function that always returns the first non-NULL item
CREATE OR REPLACE FUNCTION public.first_agg ( anyelement, anyelement )
RETURNS anyelement LANGUAGE SQL IMMUTABLE STRICT AS $$
        SELECT $1;
$$;

-- And then wrap an aggregate around it
CREATE AGGREGATE public.FIRST (
        sfunc    = public.first_agg,
        basetype = anyelement,
        stype    = anyelement
);

-- Create a function that always returns the last non-NULL item
CREATE OR REPLACE FUNCTION public.last_agg ( anyelement, anyelement )
RETURNS anyelement LANGUAGE SQL IMMUTABLE STRICT AS $$
        SELECT $2;
$$;

-- And then wrap an aggregate around it
CREATE AGGREGATE public.LAST (
        sfunc    = public.last_agg,
        basetype = anyelement,
        stype    = anyelement
);
-- *************************************************************************