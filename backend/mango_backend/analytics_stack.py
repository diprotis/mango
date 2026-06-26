"""Analytics data lake + feature store + events ingestion.

Composes the storage and catalog side of the Mango analytics platform (spec
``0006-data-lake.md``):

* an **analytics S3 bucket** with zoned key prefixes (``raw/``, ``events/``,
  ``curated/``, ``feature-store/``) and a raw→IA→Glacier lifecycle;
* a **Kinesis Data Firehose** delivery stream that lands ``POST /v1/events``
  records into ``events/dt=YYYY-MM-DD/`` as GZIP, plus its least-privilege role;
* a **Glue** database + events table so the lake is queryable from Athena;
* a **feature-store DynamoDB table** (online store for per-user/book aggregates).

Only L1 (``Cfn*``) constructs are used for Firehose/Glue so the stack stays on the
boto3 + stdlib toolchain with no extra packaging. The API stack consumes
``analytics_bucket``, ``delivery_stream_name`` and ``features_table``.
"""

from aws_cdk import Duration, RemovalPolicy, Stack
from aws_cdk import aws_dynamodb as ddb
from aws_cdk import aws_glue as glue
from aws_cdk import aws_iam as iam
from aws_cdk import aws_kinesisfirehose as firehose
from aws_cdk import aws_s3 as s3
from constructs import Construct

# Zone prefixes inside the analytics bucket. Keeping them as constants documents
# the lake layout and keeps the Firehose prefix and Glue location in sync.
RAW_PREFIX = "raw/"
EVENTS_PREFIX = "events/"
CURATED_PREFIX = "curated/"
FEATURE_STORE_PREFIX = "feature-store/"


class AnalyticsStack(Stack):
    def __init__(self, scope: Construct, construct_id: str, *, config: dict, **kwargs):
        super().__init__(scope, construct_id, **kwargs)
        stage = config["environment"]
        is_prod = stage == "prod"
        removal = RemovalPolicy.RETAIN if is_prod else RemovalPolicy.DESTROY

        # --- Analytics S3 bucket (the data lake) --------------------------------
        # Zones live under key prefixes (raw/, events/, curated/, feature-store/).
        # Raw/event objects are immutable logs, so age them down to cheaper tiers.
        self.analytics_bucket = s3.Bucket(
            self,
            "AnalyticsBucket",
            block_public_access=s3.BlockPublicAccess.BLOCK_ALL,
            encryption=s3.BucketEncryption.S3_MANAGED,
            enforce_ssl=True,
            removal_policy=removal,
            auto_delete_objects=not is_prod,
            lifecycle_rules=[
                s3.LifecycleRule(
                    id="raw-events-tiering",
                    enabled=True,
                    prefix=None,  # applies to the whole bucket
                    transitions=[
                        s3.Transition(
                            storage_class=s3.StorageClass.INFREQUENT_ACCESS,
                            transition_after=Duration.days(30),
                        ),
                        s3.Transition(
                            storage_class=s3.StorageClass.GLACIER,
                            transition_after=Duration.days(90),
                        ),
                    ],
                )
            ],
        )

        # --- Firehose delivery role --------------------------------------------
        # Least-privilege: Firehose only needs to enumerate and write objects in
        # the analytics bucket (and read it for multipart bookkeeping).
        firehose_role = iam.Role(
            self,
            "FirehoseRole",
            assumed_by=iam.ServicePrincipal("firehose.amazonaws.com"),
        )
        self.analytics_bucket.grant_read_write(firehose_role)

        # --- Kinesis Firehose delivery stream ----------------------------------
        # Events POSTed to the API are put_record'd here and buffered to S3 as
        # date-partitioned GZIP under events/dt=YYYY-MM-DD/.
        self.delivery_stream = firehose.CfnDeliveryStream(
            self,
            "EventsDeliveryStream",
            delivery_stream_name=f"mango-events-{stage}",
            delivery_stream_type="DirectPut",
            extended_s3_destination_configuration=(
                firehose.CfnDeliveryStream.ExtendedS3DestinationConfigurationProperty(
                    bucket_arn=self.analytics_bucket.bucket_arn,
                    role_arn=firehose_role.role_arn,
                    prefix=f"{EVENTS_PREFIX}dt=!{{timestamp:yyyy-MM-dd}}/",
                    error_output_prefix="events-errors/",
                    compression_format="GZIP",
                    buffering_hints=firehose.CfnDeliveryStream.BufferingHintsProperty(
                        size_in_m_bs=64,
                        interval_in_seconds=60,
                    ),
                )
            ),
        )
        # The CfnDeliveryStream's ``ref`` resolves to the stream name, which is
        # exactly what the events Lambda passes as DeliveryStreamName.
        self.delivery_stream_name = self.delivery_stream.ref

        # --- Glue catalog: database + events table -----------------------------
        # Lets Athena query the JSON event log in place. Partitioned by ``dt`` so
        # queries can prune to a date range.
        self.glue_database = glue.CfnDatabase(
            self,
            "GlueDatabase",
            catalog_id=self.account,
            database_input=glue.CfnDatabase.DatabaseInputProperty(
                name=f"mango_{stage}",
                description=f"Mango analytics lake ({stage})",
            ),
        )

        events_location = f"s3://{self.analytics_bucket.bucket_name}/{EVENTS_PREFIX}"
        self.events_table = glue.CfnTable(
            self,
            "EventsGlueTable",
            catalog_id=self.account,
            database_name=f"mango_{stage}",
            table_input=glue.CfnTable.TableInputProperty(
                name="events",
                description="Raw analytics events (Firehose → S3, JSON).",
                table_type="EXTERNAL_TABLE",
                parameters={"classification": "json"},
                partition_keys=[
                    glue.CfnTable.ColumnProperty(name="dt", type="string"),
                ],
                storage_descriptor=glue.CfnTable.StorageDescriptorProperty(
                    location=events_location,
                    input_format="org.apache.hadoop.mapred.TextInputFormat",
                    output_format=("org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"),
                    columns=[
                        glue.CfnTable.ColumnProperty(name="ts", type="string"),
                        glue.CfnTable.ColumnProperty(name="type", type="string"),
                        glue.CfnTable.ColumnProperty(name="userId", type="string"),
                        glue.CfnTable.ColumnProperty(name="props", type="string"),
                    ],
                    serde_info=glue.CfnTable.SerdeInfoProperty(
                        serialization_library="org.openx.data.jsonserde.JsonSerDe",
                    ),
                ),
            ),
        )
        # Table references the database by name; make the dependency explicit.
        self.events_table.add_dependency(self.glue_database)

        # --- Online feature store (DynamoDB) -----------------------------------
        # entityId is e.g. USER#<sub> or BOOK#<id>; featureName is the aggregate
        # (e.g. "xp_7d", "completion_rate"). PAY_PER_REQUEST keeps it serverless.
        self.features_table = ddb.Table(
            self,
            "FeaturesTable",
            table_name=f"MangoFeatures-{stage}",
            partition_key=ddb.Attribute(name="entityId", type=ddb.AttributeType.STRING),
            sort_key=ddb.Attribute(name="featureName", type=ddb.AttributeType.STRING),
            billing_mode=ddb.BillingMode.PAY_PER_REQUEST,
            point_in_time_recovery_specification=ddb.PointInTimeRecoverySpecification(
                point_in_time_recovery_enabled=is_prod
            ),
            removal_policy=removal,
        )
