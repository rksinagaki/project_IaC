import os
import boto3
import json
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# boto3クライアントを初期化
s3 = boto3.resource('s3')
glue = boto3.client('glue')

# 環境変数 (Glueカタログを削除する場合に利用)
GLUE_DATABASE_NAME = os.environ.get('GLUE_DATABASE_NAME')

def delete_s3_prefix(bucket_name, prefix):
    logger.info(f"S3バケットの削除を開始します。 ターゲットプレフィックス: s3://{bucket_name}/{prefix}")
    
    try:
        bucket = s3.Bucket(bucket_name)
        delete_response = bucket.objects.filter(Prefix=prefix).delete()
        
        # 削除されたオブジェクトの総数をカウント
        deleted_count = sum(len(d.get('Deleted', [])) for d in delete_response)
        logger.info(f"S3クリーンアップが完了しました。削除されたオブジェクト総数: {deleted_count}")
        
    except Exception as e:
        # クリーンアップ自体の失敗はログに記録し、Lambdaを停止させません。
        logger.error(f"Error deleting S3 prefix {prefix} in {bucket_name}: {e}")

def lambda_handler(event, context):
    logger.info(f"Received cleanup event: {json.dumps(event)}")

    try:
        # 情報の抽出（確認済みのシンプルなロジック）
        decoded_payload = event.get('decoded_payload')
        
        if not decoded_payload or not isinstance(decoded_payload, dict):
            logger.error("Could not find valid 'decoded_payload' in the event.")
            return {'statusCode': 200, 'body': 'Failed to parse payload. Skipping cleanup.'}

        bucket_name = decoded_payload.get('bucket_name')
        processed_base_path = decoded_payload.get('processed_base_path')
        
        if not bucket_name or not processed_base_path:
            logger.error("Missing bucket_name or processed_base_path. Cannot perform S3 cleanup.")
            return {'statusCode': 200, 'body': 'Missing path info. Skipping cleanup.'}

        # ここから
        # 1. full_key から bucket_name を除去してS3キーを取得
        if processed_base_path.startswith(bucket_name + '/'):
            full_key = processed_base_path.replace(bucket_name + '/', '', 1)
        else:
            full_key = processed_base_path
        
        # 2. クリーンアップの基点となる親フォルダのプレフィックスを特定
        cleanup_base_prefix = full_key.split('/processed_data/')[0]
        
        final_cleanup_key = cleanup_base_prefix + '/'
        logger.info(f"Identified execution-wide cleanup key: {final_cleanup_key}")
        
        # 3. 実行IDに関連する S3 上のすべてのデータを削除
        delete_s3_prefix(bucket_name, final_cleanup_key)
        
    except Exception as e:
        logger.error(f"Critical error during cleanup execution: {e}", exc_info=True)
        return {'statusCode': 200, 'body': 'Critical failure in cleanup. Finished with error logging.'}
    
    return {'statusCode': 200, 'body': 'Cleanup finished.'}

# def delete_glue_table(database_name, table_name):
#     glue = boto3.client('glue')
#     logger.info(f"Deleting Glue table: {database_name}.{table_name}")
#     try:
#         glue.delete_table(
#             DatabaseName=database_name,
#             Name=table_name
#         )
#         logger.info("Glue table deleted successfully.")
#     except glue.exceptions.EntityNotFoundException:
#         logger.warning(f"Glue table not found (may have been deleted): {table_name}")
#     except Exception as e:
#         logger.error(f"Error deleting Glue table: {e}")