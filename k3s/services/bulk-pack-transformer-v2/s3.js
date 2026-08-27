const AWS = require('aws-sdk');

const options = {
  accessKeyId: process.env.S3_ACCESS_KEY_ID,
  secretAccessKey: process.env.S3_SECRET_ACCESS_KEY,
};

// LocalStack (or any S3-compatible endpoint) support for the fully-local stand-up.
// Production leaves AWS_ENDPOINT unset, so this block is a no-op there and the client
// targets real AWS exactly as before. When AWS_ENDPOINT is set, force path-style
// addressing (LocalStack serves buckets on a path, not a vhost subdomain) and pin the
// region so S3 and the rest of the pipeline agree end to end.
if (process.env.AWS_ENDPOINT) {
  options.endpoint = process.env.AWS_ENDPOINT;
  options.s3ForcePathStyle = true;
  options.region = process.env.AWS_REGION;
}

const s3 = new AWS.S3(options);

module.exports = s3;
