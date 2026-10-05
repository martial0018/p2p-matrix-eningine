window.MATRIX_SUPABASE_URL = 'https://fhsgstymzmyaeuvvrqyd.supabase.co';
window.MATRIX_SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZoc2dzdHltem15YWV1dnZycXlkIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTAwNTUwNzUsImV4cCI6MjEwNTYzMTA3NX0.jVn_SJr_4vSeUVxo5lcvoAOEcXqRia4wqgKuaKIphFg';

// Local development domains. Replace with your real DNS domains before deployment.
// Localhost and file URLs are treated as development-safe bypasses so the app can be
// tested without a role-specific hostname while production deployments still enforce
// the host-based role guard.
window.MATRIX_ROLE_DOMAINS = {
	admin: 'admin.localhost',
	moderator: 'moderator.localhost',
	arbiter: 'arbiter.localhost',
	regular: 'user.localhost'
};
