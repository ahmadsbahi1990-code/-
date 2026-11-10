-- Local-only Supabase Storage catalog stand-in. This tests SQL/RLS, not S3 I/O.
CREATE SCHEMA storage;
CREATE TABLE storage.buckets(
  id text PRIMARY KEY,name text NOT NULL UNIQUE,public boolean NOT NULL DEFAULT false,
  file_size_limit bigint,allowed_mime_types text[]
);
CREATE TABLE storage.objects(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),bucket_id text REFERENCES storage.buckets(id),
  name text NOT NULL,metadata jsonb,UNIQUE(bucket_id,name)
);
ALTER TABLE storage.buckets ENABLE ROW LEVEL SECURITY;
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
GRANT USAGE ON SCHEMA storage TO anon,authenticated;
GRANT SELECT,INSERT,UPDATE,DELETE ON storage.buckets,storage.objects TO anon,authenticated;
-- Deliberately dangerous pre-existing policies for unrelated buckets. The new
-- restrictive policies must still protect only the KENZ bucket.
CREATE POLICY prior_broad_objects ON storage.objects FOR ALL TO PUBLIC USING(true) WITH CHECK(true);
CREATE POLICY prior_broad_buckets ON storage.buckets FOR ALL TO PUBLIC USING(true) WITH CHECK(true);
INSERT INTO storage.buckets(id,name,public) VALUES('unrelated-public','unrelated-public',true);
INSERT INTO storage.objects(bucket_id,name) VALUES('unrelated-public','public-image.png');
