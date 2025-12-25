# AboutBlank Railway Deployment Guide

## Prerequisites
- Railway account with Pro plan ($20/month)
- Railway CLI installed: `npm install -g @railway/cli`

## Step 1: Create PostgreSQL Database

```bash
# Login to Railway
railway login

# Create new project
railway init aboutblank-production

# Add PostgreSQL plugin
railway add postgresql

# Note the DATABASE_URL from the dashboard
```

## Step 2: Deploy API Server

```bash
# Navigate to railway folder
cd railway

# Link to Railway project
railway link

# Deploy the API server
railway up

# Set environment variables in Railway dashboard:
# - DATABASE_URL (automatically set by PostgreSQL plugin)
# - NODE_ENV=production
# - PORT=8080 (automatically set by Railway)
```

## Step 3: Initialize Database Schema

```bash
# Connect to PostgreSQL
railway connect postgresql

# Copy and paste the SQL from deployment-config.sql
# Or run:
cat deployment-config.sql | railway run psql $DATABASE_URL
```

## Step 4: Update Flutter App

Edit `lib/services/postgres_sync_service.dart`:

```dart
static const String apiUrl = 'https://YOUR-RAILWAY-APP.up.railway.app';
```

Get your Railway URL from: `railway domain`

## Step 5: Test Connection

```bash
# Test health endpoint
curl https://YOUR-RAILWAY-APP.up.railway.app/health

# Expected response:
# {"status":"healthy","timestamp":"2025-12-25T..."}
```

## Railway Configuration

### Connection Pooling (PgBouncer)
Railway automatically provides PgBouncer for connection pooling. No additional configuration needed.

### Performance Settings
- Max pool size: 20 connections
- Idle timeout: 30 seconds
- Connection timeout: 10 seconds

### Rate Limiting
- API endpoints: 100 requests per 15 minutes per IP
- Auth endpoints: 5 attempts per hour (prevents brute force)

### Monitoring
Railway dashboard provides:
- Request logs
- Error tracking
- Resource usage (CPU, memory, bandwidth)
- Database metrics

## Scaling for Hundreds of Users

Current Railway Pro plan supports:
- **Database**: 8GB RAM, 100GB storage
- **API**: 8GB RAM, unlimited requests
- **Bandwidth**: 100GB/month (should handle ~500 active users)

If you exceed 500 users:
1. Upgrade to Railway Team plan ($99/month)
2. Add CDN for static assets (Cloudflare)
3. Consider read replicas for PostgreSQL

## Security Checklist

- [x] SHA-256 authentication hashes
- [x] Rate limiting (100 req/15min)
- [x] CORS restricted to aboutblank.ie
- [x] Helmet security headers
- [x] SSL/TLS encryption (automatic on Railway)
- [x] Connection pooling
- [x] SQL injection protection (parameterized queries)
- [x] Request size limits (1MB max)
- [x] Gzip compression

## Cost Estimate

### Railway Pro ($20/month)
- PostgreSQL: 8GB RAM, 100GB storage
- API server: 8GB RAM
- 100GB bandwidth

### Total: $20/month for 100-500 concurrent users

## Troubleshooting

### Connection Issues
```bash
# Check API status
railway status

# View logs
railway logs

# Connect to database
railway run psql $DATABASE_URL
```

### High Load
```bash
# Monitor active connections
SELECT count(*) FROM pg_stat_activity;

# Check slow queries
SELECT query, mean_exec_time 
FROM pg_stat_statements 
ORDER BY mean_exec_time DESC 
LIMIT 10;
```

### Rate Limit Errors
If users hit rate limits, adjust in server.js:
```javascript
const apiLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 200, // Increase from 100 to 200
});
```

## Backup Strategy

Railway automatically backs up PostgreSQL daily. To manually backup:

```bash
# Export database
railway run pg_dump $DATABASE_URL > backup.sql

# Restore database
railway run psql $DATABASE_URL < backup.sql
```

## Production Deployment Checklist

- [ ] PostgreSQL database created on Railway
- [ ] API server deployed and running
- [ ] Database schema initialized
- [ ] Flutter app updated with production API URL
- [ ] Rate limiting tested
- [ ] Authentication tested
- [ ] Data persistence tested (clear cache, data still loads)
- [ ] Monitoring dashboard set up
- [ ] Backup strategy confirmed
- [ ] SSL certificate active (automatic on Railway)
- [ ] CORS configured for production domain

## Support

Railway support: https://railway.app/help
AboutBlank issues: [Your GitHub repo]
