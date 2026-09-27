module.exports=`
CREATE TABLE IF NOT EXISTS groups(id uuid PRIMARY KEY,name text);
CREATE TABLE message_requests(id uuid PRIMARY KEY,sender_id uuid,recipient_id uuid,created_at timestamptz DEFAULT now(),status text DEFAULT 'pending',audit_operation_id uuid,audit_parent_event_id bigint,resolved_at timestamptz,rejection_reason text,rejection_code text,type text,body text,file_url text,file_name text);
CREATE TABLE messages(id uuid PRIMARY KEY,created_at timestamptz DEFAULT now(),sender_id uuid,recipient_id uuid,group_id uuid,type text,body text,file_name text,file_url text,delivery_summary jsonb);
CREATE TABLE stored_files(id uuid PRIMARY KEY,public_url text,file_type text,original_name text,moderation_status text,moderation_details jsonb);
CREATE TABLE pending_scans(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,file_type text,file_name text,retry_count int DEFAULT 0,audit_operation_id uuid);
CREATE TABLE message_status(message_id uuid,user_id uuid,status text);
`;
