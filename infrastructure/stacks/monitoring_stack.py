from typing import List
from aws_cdk import (
    Stack,
    aws_cloudwatch as cloudwatch,
    aws_cloudwatch_actions as cloudwatch_actions,
    aws_sns as sns,
    aws_sns_subscriptions as subscriptions,
    aws_logs as logs,
    CfnOutput,
    Duration
)
from constructs import Construct
from aws_cdk.aws_lambda import IFunction


class MonitoringStack(Stack):
    """Monitoring and observability stack including CloudWatch dashboards and alarms."""
    
    def __init__(self, scope: Construct, construct_id: str, config: dict, lambda_functions: List[IFunction], **kwargs) -> None:
        super().__init__(scope, construct_id, **kwargs)
        
        self.config = config
        self.stage = config["environment"]
        self.lambda_functions = lambda_functions
        
        # Create SNS topic for alarms
        self.alarm_topic = self._create_alarm_topic()
        
        # Create CloudWatch dashboard
        self.dashboard = self._create_dashboard()
        
        # Create alarms
        self._create_lambda_alarms()
        
        # Create log groups
        self._create_log_groups()
        
        # Create outputs
        self._create_outputs()
    
    def _create_alarm_topic(self) -> sns.Topic:
        """Create SNS topic for alarm notifications."""
        topic = sns.Topic(
            self,
            f"AlarmTopic-{self.stage}",
            topic_name=f"{self.config['projectName']}-alarms-{self.stage}",
            display_name=f"Reading Journey Alarms - {self.stage.upper()}"
        )
        
        # Add email subscription
        if "alarmEmail" in self.config["monitoring"]:
            topic.add_subscription(
                subscriptions.EmailSubscription(self.config["monitoring"]["alarmEmail"])
            )
        
        return topic
    
    def _create_dashboard(self) -> cloudwatch.Dashboard:
        """Create CloudWatch dashboard for monitoring."""
        dashboard = cloudwatch.Dashboard(
            self,
            f"Dashboard-{self.stage}",
            dashboard_name=f"{self.config['projectName']}-{self.stage}",
            default_interval=Duration.hours(3)
        )
        
        # Add Lambda metrics widgets
        for idx, function in enumerate(self.lambda_functions):
            # Invocations widget
            invocations_widget = cloudwatch.GraphWidget(
                title=f"{function.function_name} - Invocations",
                left=[
                    function.metric_invocations(
                        statistic=cloudwatch.Stats.SUM,
                        period=Duration.minutes(5)
                    )
                ],
                right=[
                    function.metric_errors(
                        statistic=cloudwatch.Stats.SUM,
                        period=Duration.minutes(5)
                    )
                ],
                width=12,
                height=6
            )
            
            # Duration widget
            duration_widget = cloudwatch.GraphWidget(
                title=f"{function.function_name} - Duration",
                left=[
                    function.metric_duration(
                        statistic=cloudwatch.Stats.AVERAGE,
                        period=Duration.minutes(5)
                    ),
                    function.metric_duration(
                        statistic=cloudwatch.Stats.P99,
                        period=Duration.minutes(5)
                    )
                ],
                width=12,
                height=6
            )
            
            # Add widgets to dashboard
            if idx == 0:
                dashboard.add_widgets(invocations_widget, duration_widget)
            else:
                dashboard.add_widgets(invocations_widget, duration_widget)
        
        # Add text widget with environment info
        info_widget = cloudwatch.TextWidget(
            markdown=f"""
# Reading Journey Backend - {self.stage.upper()}

## Environment Information
- **Stage**: {self.stage}
- **Region**: {self.stack.region}
- **Account**: {self.stack.account}

## Key Metrics
- Lambda invocations and errors
- Lambda duration (average and P99)
- Concurrent executions

## Alarm Configuration
- Error rate threshold: 1%
- Duration threshold: 80% of timeout
            """,
            width=24,
            height=4
        )
        
        dashboard.add_widgets(info_widget)
        
        return dashboard
    
    def _create_lambda_alarms(self):
        """Create CloudWatch alarms for Lambda functions."""
        for function in self.lambda_functions:
            # Error rate alarm
            error_alarm = cloudwatch.Alarm(
                self,
                f"{function.function_name}-ErrorAlarm",
                alarm_name=f"{function.function_name}-errors-{self.stage}",
                metric=function.metric_errors(
                    statistic=cloudwatch.Stats.SUM,
                    period=Duration.minutes(5)
                ),
                threshold=5,
                evaluation_periods=2,
                comparison_operator=cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
                alarm_description=f"Lambda function {function.function_name} error rate is too high",
                treat_missing_data=cloudwatch.TreatMissingData.NOT_BREACHING
            )
            error_alarm.add_alarm_action(
                cloudwatch_actions.SnsAction(self.alarm_topic)
            )
            
            # Duration alarm (80% of timeout)
            timeout_seconds = self.config["lambda"]["timeout"]
            duration_alarm = cloudwatch.Alarm(
                self,
                f"{function.function_name}-DurationAlarm",
                alarm_name=f"{function.function_name}-duration-{self.stage}",
                metric=function.metric_duration(
                    statistic=cloudwatch.Stats.AVERAGE,
                    period=Duration.minutes(5)
                ),
                threshold=timeout_seconds * 0.8 * 1000,  # Convert to milliseconds
                evaluation_periods=2,
                comparison_operator=cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
                alarm_description=f"Lambda function {function.function_name} is approaching timeout",
                treat_missing_data=cloudwatch.TreatMissingData.NOT_BREACHING
            )
            duration_alarm.add_alarm_action(
                cloudwatch_actions.SnsAction(self.alarm_topic)
            )
            
            # Throttles alarm
            throttle_alarm = cloudwatch.Alarm(
                self,
                f"{function.function_name}-ThrottleAlarm",
                alarm_name=f"{function.function_name}-throttles-{self.stage}",
                metric=function.metric_throttles(
                    statistic=cloudwatch.Stats.SUM,
                    period=Duration.minutes(5)
                ),
                threshold=1,
                evaluation_periods=1,
                comparison_operator=cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
                alarm_description=f"Lambda function {function.function_name} is being throttled",
                treat_missing_data=cloudwatch.TreatMissingData.NOT_BREACHING
            )
            throttle_alarm.add_alarm_action(
                cloudwatch_actions.SnsAction(self.alarm_topic)
            )
    
    def _create_log_groups(self):
        """Create custom log groups for application logging."""
        # Application log group
        app_log_group = logs.LogGroup(
            self,
            f"AppLogGroup-{self.stage}",
            log_group_name=f"/aws/application/{self.config['projectName']}/{self.stage}",
            retention=logs.RetentionDays.SEVEN_DAYS if self.stage == "beta" else logs.RetentionDays.THIRTY_DAYS
        )
        
        # Audit log group
        audit_log_group = logs.LogGroup(
            self,
            f"AuditLogGroup-{self.stage}",
            log_group_name=f"/aws/audit/{self.config['projectName']}/{self.stage}",
            retention=logs.RetentionDays.THIRTY_DAYS if self.stage == "beta" else logs.RetentionDays.ONE_YEAR
        )
    
    def _create_outputs(self):
        """Create stack outputs."""
        CfnOutput(
            self,
            "DashboardUrl",
            value=f"https://console.aws.amazon.com/cloudwatch/home?region={self.stack.region}#dashboards:name={self.dashboard.dashboard_name}",
            description=f"CloudWatch Dashboard URL for {self.stage} environment"
        )
        
        CfnOutput(
            self,
            "AlarmTopicArn",
            value=self.alarm_topic.topic_arn,
            description=f"SNS topic ARN for alarms in {self.stage} environment"
        )
