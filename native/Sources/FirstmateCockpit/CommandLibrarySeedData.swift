// Manjesh Grand Line - native macOS app.
//
// Built-in starter content for the DevOps Command Library
// (fm/grandline-devops-command-library, Phase 1). Real, correct, genuinely
// useful commands an SRE actually runs - not placeholder text - covering
// every category the design doc's mockup lists. `CommandLibraryStore.
// seedIfEmpty()` writes these to disk the first time the store finds an
// empty `commands/` folder; a command's own `id` here is a bare slug (see
// that method's doc comment for why it's never the full category-prefixed
// path).
//
// Namespace/region/environment-shaped parameters use `configOptionsKey`
// rather than a hardcoded `options` list, per the original spec's explicit
// "never hardcode environment/namespace names into the app" instruction -
// `CommandLibrarySeedData.config` seeds a reasonable starting
// `commands/config.yaml` the captain can freely edit afterward.

import Foundation

enum CommandLibrarySeedData {

    static let config = CommandLibraryConfig(selectOptions: [
        "namespaces": ["default", "raas-prod", "raas-uat", "platform"],
        "environments": ["dev", "staging", "uat", "prod"],
        "aws_regions": ["us-east-1", "us-west-2", "eu-west-1"],
    ])

    static let commands: [DevOpsCommand] = kubernetes + aws + linux + docker + git + mysql + networking + openssl + terraform + helm + argocd + jenkins + general

    // MARK: Kubernetes

    private static let kubernetes: [DevOpsCommand] = [
        DevOpsCommand(
            id: "get-pod-logs", name: "Get Pod Logs",
            description: "Get logs from a Kubernetes pod", category: "kubernetes", subcategory: "pods",
            commandTemplate: "kubectl logs -n {{namespace}} {{pod}} --since={{duration}}",
            parameters: [
                CommandParameter(name: "namespace", label: "Namespace", kind: .select, configOptionsKey: "namespaces", placeholder: "raas-prod"),
                CommandParameter(name: "pod", label: "Pod", defaultValue: "search-api"),
                CommandParameter(name: "duration", label: "Duration", defaultValue: "30m"),
            ],
            tags: ["kubectl", "logs", "troubleshooting"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "describe-pod", name: "Describe Pod",
            description: "Show detailed state, events, and conditions for a pod", category: "kubernetes", subcategory: "pods",
            commandTemplate: "kubectl describe pod -n {{namespace}} {{pod}}",
            parameters: [
                CommandParameter(name: "namespace", label: "Namespace", kind: .select, configOptionsKey: "namespaces"),
                CommandParameter(name: "pod", label: "Pod"),
            ],
            tags: ["kubectl", "troubleshooting"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "exec-into-pod", name: "Exec Into Pod",
            description: "Open an interactive shell inside a running pod", category: "kubernetes", subcategory: "pods",
            commandTemplate: "kubectl exec -it -n {{namespace}} {{pod}} -- {{shell}}",
            parameters: [
                CommandParameter(name: "namespace", label: "Namespace", kind: .select, configOptionsKey: "namespaces"),
                CommandParameter(name: "pod", label: "Pod"),
                CommandParameter(name: "shell", label: "Shell", defaultValue: "/bin/sh"),
            ],
            tags: ["kubectl", "shell", "debug"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "get-pods-by-label", name: "Get Pods by Label",
            description: "List pods matching a label selector", category: "kubernetes",
            commandTemplate: "kubectl get pods -n {{namespace}} -l {{label}}",
            parameters: [
                CommandParameter(name: "namespace", label: "Namespace", kind: .select, configOptionsKey: "namespaces"),
                CommandParameter(name: "label", label: "Label selector", defaultValue: "app=search-api"),
            ],
            tags: ["kubectl", "pods"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "restart-deployment", name: "Restart Deployment",
            description: "Roll every pod in a deployment via a rolling restart", category: "kubernetes",
            commandTemplate: "kubectl rollout restart deployment/{{deployment}} -n {{namespace}}",
            parameters: [
                CommandParameter(name: "deployment", label: "Deployment"),
                CommandParameter(name: "namespace", label: "Namespace", kind: .select, configOptionsKey: "namespaces"),
            ],
            tags: ["kubectl", "deployment", "restart"], risk: .potentiallyDisruptive
        ),
        DevOpsCommand(
            id: "scale-deployment", name: "Scale Deployment",
            description: "Change a deployment's replica count", category: "kubernetes",
            commandTemplate: "kubectl scale deployment/{{deployment}} -n {{namespace}} --replicas={{replicas}}",
            parameters: [
                CommandParameter(name: "deployment", label: "Deployment"),
                CommandParameter(name: "namespace", label: "Namespace", kind: .select, configOptionsKey: "namespaces"),
                CommandParameter(name: "replicas", label: "Replicas", kind: .number, defaultValue: "3"),
            ],
            tags: ["kubectl", "scale", "deployment"], risk: .potentiallyDisruptive
        ),
        DevOpsCommand(
            id: "delete-pod", name: "Delete Pod",
            description: "Force-delete a single pod (its controller will normally recreate it)", category: "kubernetes", subcategory: "troubleshooting",
            commandTemplate: "kubectl delete pod {{pod}} -n {{namespace}}",
            parameters: [
                CommandParameter(name: "pod", label: "Pod"),
                CommandParameter(name: "namespace", label: "Namespace", kind: .select, configOptionsKey: "namespaces"),
            ],
            tags: ["kubectl", "delete", "troubleshooting"], risk: .destructive
        ),
        DevOpsCommand(
            id: "port-forward", name: "Port Forward",
            description: "Forward a local port to a service inside the cluster", category: "kubernetes",
            commandTemplate: "kubectl port-forward -n {{namespace}} svc/{{service}} {{local_port}}:{{remote_port}}",
            parameters: [
                CommandParameter(name: "namespace", label: "Namespace", kind: .select, configOptionsKey: "namespaces"),
                CommandParameter(name: "service", label: "Service"),
                CommandParameter(name: "local_port", label: "Local port", kind: .number, defaultValue: "8080"),
                CommandParameter(name: "remote_port", label: "Remote port", kind: .number, defaultValue: "80"),
            ],
            tags: ["kubectl", "networking", "debug"], risk: .readOnly
        ),
    ]

    // MARK: AWS

    private static let aws: [DevOpsCommand] = [
        DevOpsCommand(
            id: "list-ec2-instances", name: "List EC2 Instances",
            description: "List EC2 instances filtered by a tag value", category: "aws",
            commandTemplate: "aws ec2 describe-instances --region {{region}} --filters \"Name=tag:Name,Values={{tag_value}}\"",
            parameters: [
                CommandParameter(name: "region", label: "Region", kind: .select, configOptionsKey: "aws_regions"),
                CommandParameter(name: "tag_value", label: "Tag value", defaultValue: "*"),
            ],
            tags: ["aws", "ec2"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "get-s3-bucket-size", name: "Get S3 Bucket Size",
            description: "Sum object sizes in an S3 bucket (or prefix)", category: "aws",
            commandTemplate: "aws s3 ls s3://{{bucket}} --recursive --summarize",
            parameters: [CommandParameter(name: "bucket", label: "Bucket")],
            tags: ["aws", "s3"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "tail-cloudwatch-logs", name: "Tail CloudWatch Logs",
            description: "Stream recent CloudWatch Logs for a log group", category: "aws",
            commandTemplate: "aws logs tail {{log_group}} --since {{duration}} --follow",
            parameters: [
                CommandParameter(name: "log_group", label: "Log group"),
                CommandParameter(name: "duration", label: "Since", defaultValue: "1h"),
            ],
            tags: ["aws", "cloudwatch", "logs"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "describe-rds-instance", name: "Describe RDS Instance",
            description: "Show status/config details for an RDS instance", category: "aws",
            commandTemplate: "aws rds describe-db-instances --db-instance-identifier {{db_instance}}",
            parameters: [CommandParameter(name: "db_instance", label: "DB instance identifier")],
            tags: ["aws", "rds"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "list-lambda-functions", name: "List Lambda Functions",
            description: "List Lambda functions in a region", category: "aws",
            commandTemplate: "aws lambda list-functions --region {{region}}",
            parameters: [CommandParameter(name: "region", label: "Region", kind: .select, configOptionsKey: "aws_regions")],
            tags: ["aws", "lambda"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "assume-role", name: "Assume Role",
            description: "Assume an IAM role and print temporary credentials", category: "aws",
            commandTemplate: "aws sts assume-role --role-arn {{role_arn}} --role-session-name {{session_name}}",
            parameters: [
                CommandParameter(name: "role_arn", label: "Role ARN"),
                CommandParameter(name: "session_name", label: "Session name", defaultValue: "grandline-session"),
            ],
            tags: ["aws", "iam", "sts"], risk: .readOnly
        ),
    ]

    // MARK: Linux

    private static let linux: [DevOpsCommand] = [
        DevOpsCommand(
            id: "check-disk-usage", name: "Check Disk Usage",
            description: "Show disk space usage for all mounted filesystems", category: "linux",
            commandTemplate: "df -h",
            tags: ["disk", "filesystem"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "find-large-files", name: "Find Large Files",
            description: "Find files larger than a given size under a path", category: "linux",
            commandTemplate: "find {{path}} -type f -size +{{size}} -exec ls -lh {} \\;",
            parameters: [
                CommandParameter(name: "path", label: "Path", defaultValue: "/var/log"),
                CommandParameter(name: "size", label: "Size (e.g. 100M)", defaultValue: "100M"),
            ],
            tags: ["disk", "find"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "top-processes-by-memory", name: "Top Processes by Memory",
            description: "List the top memory-consuming processes", category: "linux",
            commandTemplate: "ps aux --sort=-%mem | head -n {{count}}",
            parameters: [CommandParameter(name: "count", label: "Count", kind: .number, defaultValue: "10")],
            tags: ["processes", "memory"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "check-listening-ports", name: "Check Listening Ports",
            description: "List processes with open listening sockets", category: "linux",
            commandTemplate: "sudo lsof -i -P -n | grep LISTEN",
            tags: ["networking", "ports"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "tail-log-file", name: "Tail Log File",
            description: "Follow the tail of a log file", category: "linux",
            commandTemplate: "tail -f -n {{lines}} {{file}}",
            parameters: [
                CommandParameter(name: "lines", label: "Lines", kind: .number, defaultValue: "200"),
                CommandParameter(name: "file", label: "File", defaultValue: "/var/log/syslog"),
            ],
            tags: ["logs"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "check-system-load", name: "Check System Load",
            description: "Show load averages and a short vmstat sample", category: "linux",
            commandTemplate: "uptime && vmstat 1 5",
            tags: ["performance", "load"], risk: .readOnly
        ),
    ]

    // MARK: Docker

    private static let docker: [DevOpsCommand] = [
        DevOpsCommand(
            id: "list-running-containers", name: "List Running Containers",
            description: "List all currently running containers", category: "docker",
            commandTemplate: "docker ps",
            tags: ["docker", "containers"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "view-container-logs", name: "View Container Logs",
            description: "Follow the tail of a container's logs", category: "docker",
            commandTemplate: "docker logs -f --tail {{lines}} {{container}}",
            parameters: [
                CommandParameter(name: "lines", label: "Lines", kind: .number, defaultValue: "200"),
                CommandParameter(name: "container", label: "Container"),
            ],
            tags: ["docker", "logs"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "exec-into-container", name: "Exec Into Container",
            description: "Open an interactive shell inside a running container", category: "docker",
            commandTemplate: "docker exec -it {{container}} {{shell}}",
            parameters: [
                CommandParameter(name: "container", label: "Container"),
                CommandParameter(name: "shell", label: "Shell", defaultValue: "/bin/sh"),
            ],
            tags: ["docker", "shell", "debug"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "remove-stopped-containers", name: "Remove Stopped Containers",
            description: "Delete every stopped container to reclaim disk space", category: "docker",
            commandTemplate: "docker container prune -f",
            tags: ["docker", "cleanup"], risk: .potentiallyDisruptive
        ),
        DevOpsCommand(
            id: "inspect-container", name: "Inspect Container",
            description: "Show a container's full low-level configuration", category: "docker",
            commandTemplate: "docker inspect {{container}}",
            parameters: [CommandParameter(name: "container", label: "Container")],
            tags: ["docker", "inspect"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "build-image", name: "Build Image",
            description: "Build a Docker image from a build context", category: "docker",
            commandTemplate: "docker build -t {{tag}} {{context}}",
            parameters: [
                CommandParameter(name: "tag", label: "Tag", defaultValue: "myapp:latest"),
                CommandParameter(name: "context", label: "Build context", defaultValue: "."),
            ],
            tags: ["docker", "build"], risk: .readOnly
        ),
    ]

    // MARK: Git

    private static let git: [DevOpsCommand] = [
        DevOpsCommand(
            id: "view-recent-commits", name: "View Recent Commits",
            description: "Show a compact log of the most recent commits", category: "git",
            commandTemplate: "git log --oneline -n {{count}}",
            parameters: [CommandParameter(name: "count", label: "Count", kind: .number, defaultValue: "20")],
            tags: ["git", "log"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "show-file-history", name: "Show File History",
            description: "Show every commit that touched a file, following renames", category: "git",
            commandTemplate: "git log --follow -p -- {{file}}",
            parameters: [CommandParameter(name: "file", label: "File")],
            tags: ["git", "history"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "undo-last-commit-keep-changes", name: "Undo Last Commit (Keep Changes)",
            description: "Undo the last commit but keep its changes staged", category: "git",
            commandTemplate: "git reset --soft HEAD~1",
            tags: ["git", "undo"], risk: .potentiallyDisruptive
        ),
        DevOpsCommand(
            id: "force-push-with-lease", name: "Force Push (with lease)",
            description: "Force-push a branch, refusing if the remote moved since your last fetch", category: "git",
            commandTemplate: "git push --force-with-lease origin {{branch}}",
            parameters: [CommandParameter(name: "branch", label: "Branch")],
            tags: ["git", "push"], risk: .destructive
        ),
        DevOpsCommand(
            id: "find-commit-that-introduced-line", name: "Find Commit That Introduced Line",
            description: "Search commit history for when a string was added/removed in a file", category: "git",
            commandTemplate: "git log -S \"{{search_string}}\" -- {{file}}",
            parameters: [
                CommandParameter(name: "search_string", label: "Search string"),
                CommandParameter(name: "file", label: "File"),
            ],
            tags: ["git", "search", "history"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "clean-untracked-files-dry-run", name: "Clean Untracked Files (Dry Run)",
            description: "Preview which untracked files `git clean` would remove", category: "git",
            commandTemplate: "git clean -nd",
            tags: ["git", "cleanup"], risk: .readOnly
        ),
    ]

    // MARK: MySQL

    private static let mysql: [DevOpsCommand] = [
        DevOpsCommand(
            id: "show-process-list", name: "Show Process List",
            description: "Show currently running MySQL queries/connections", category: "mysql",
            commandTemplate: "mysql -u {{user}} -p -e \"SHOW FULL PROCESSLIST;\"",
            parameters: [CommandParameter(name: "user", label: "User", defaultValue: "root")],
            tags: ["mysql", "processlist"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "dump-database", name: "Dump Database",
            description: "Dump a database to a SQL file", category: "mysql",
            commandTemplate: "mysqldump -u {{user}} -p {{database}} > {{output_file}}",
            parameters: [
                CommandParameter(name: "user", label: "User", defaultValue: "root"),
                CommandParameter(name: "database", label: "Database"),
                CommandParameter(name: "output_file", label: "Output file", defaultValue: "dump.sql"),
            ],
            tags: ["mysql", "backup"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "check-table-size", name: "Check Table Size",
            description: "List a database's tables ordered by size on disk", category: "mysql",
            commandTemplate: "mysql -u {{user}} -p -e \"SELECT table_name, ROUND(((data_length + index_length) / 1024 / 1024), 2) AS size_mb FROM information_schema.TABLES WHERE table_schema = '{{database}}' ORDER BY size_mb DESC;\"",
            parameters: [
                CommandParameter(name: "user", label: "User", defaultValue: "root"),
                CommandParameter(name: "database", label: "Database"),
            ],
            tags: ["mysql", "size"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "kill-query", name: "Kill Query",
            description: "Terminate a running MySQL query/connection by process id", category: "mysql",
            commandTemplate: "mysql -u {{user}} -p -e \"KILL {{process_id}};\"",
            parameters: [
                CommandParameter(name: "user", label: "User", defaultValue: "root"),
                CommandParameter(name: "process_id", label: "Process ID", kind: .number),
            ],
            tags: ["mysql", "kill"], risk: .potentiallyDisruptive
        ),
        DevOpsCommand(
            id: "show-slow-queries", name: "Show Slow Queries",
            description: "Show the most recent entries from the slow query log", category: "mysql",
            commandTemplate: "mysql -u {{user}} -p -e \"SELECT * FROM mysql.slow_log ORDER BY start_time DESC LIMIT {{count}};\"",
            parameters: [
                CommandParameter(name: "user", label: "User", defaultValue: "root"),
                CommandParameter(name: "count", label: "Count", kind: .number, defaultValue: "20"),
            ],
            tags: ["mysql", "performance"], risk: .readOnly
        ),
    ]

    // MARK: Networking

    private static let networking: [DevOpsCommand] = [
        DevOpsCommand(
            id: "check-open-port", name: "Check Open Port",
            description: "Check whether a TCP port is open on a host", category: "networking",
            commandTemplate: "nc -zv {{host}} {{port}}",
            parameters: [
                CommandParameter(name: "host", label: "Host"),
                CommandParameter(name: "port", label: "Port", kind: .number, defaultValue: "443"),
            ],
            tags: ["networking", "port"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "dns-lookup", name: "DNS Lookup",
            description: "Look up a DNS record for a hostname", category: "networking",
            commandTemplate: "dig {{hostname}} {{record_type}}",
            parameters: [
                CommandParameter(name: "hostname", label: "Hostname"),
                CommandParameter(name: "record_type", label: "Record type", kind: .select, defaultValue: "A", options: ["A", "AAAA", "CNAME", "MX", "TXT", "NS"]),
            ],
            tags: ["networking", "dns"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "trace-route", name: "Trace Route",
            description: "Trace the network path to a host", category: "networking",
            commandTemplate: "traceroute {{host}}",
            parameters: [CommandParameter(name: "host", label: "Host")],
            tags: ["networking", "traceroute"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "check-http-response", name: "Check HTTP Response",
            description: "Show response headers and status for a URL", category: "networking",
            commandTemplate: "curl -I {{url}}",
            parameters: [CommandParameter(name: "url", label: "URL")],
            tags: ["networking", "http", "curl"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "test-latency", name: "Test Latency",
            description: "Ping a host a fixed number of times", category: "networking",
            commandTemplate: "ping -c {{count}} {{host}}",
            parameters: [
                CommandParameter(name: "count", label: "Count", kind: .number, defaultValue: "5"),
                CommandParameter(name: "host", label: "Host"),
            ],
            tags: ["networking", "ping"], risk: .readOnly
        ),
    ]

    // MARK: OpenSSL

    private static let openssl: [DevOpsCommand] = [
        DevOpsCommand(
            id: "check-certificate-expiry", name: "Check Certificate Expiry",
            description: "Show a live TLS endpoint's certificate validity dates", category: "openssl",
            commandTemplate: "openssl s_client -connect {{host}}:{{port}} -servername {{host}} </dev/null 2>/dev/null | openssl x509 -noout -dates",
            parameters: [
                CommandParameter(name: "host", label: "Host"),
                CommandParameter(name: "port", label: "Port", kind: .number, defaultValue: "443"),
            ],
            tags: ["openssl", "certificate", "tls"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "view-certificate-details", name: "View Certificate Details",
            description: "Print the full contents of a certificate file", category: "openssl",
            commandTemplate: "openssl x509 -in {{cert_file}} -text -noout",
            parameters: [CommandParameter(name: "cert_file", label: "Certificate file")],
            tags: ["openssl", "certificate"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "generate-self-signed-cert", name: "Generate Self-Signed Cert",
            description: "Generate a new self-signed certificate and private key", category: "openssl",
            commandTemplate: "openssl req -x509 -newkey rsa:{{key_size}} -keyout {{key_file}} -out {{cert_file}} -days {{days}} -nodes",
            parameters: [
                CommandParameter(name: "key_size", label: "Key size", kind: .number, defaultValue: "2048"),
                CommandParameter(name: "key_file", label: "Key file", defaultValue: "key.pem"),
                CommandParameter(name: "cert_file", label: "Certificate file", defaultValue: "cert.pem"),
                CommandParameter(name: "days", label: "Valid for (days)", kind: .number, defaultValue: "365"),
            ],
            tags: ["openssl", "certificate", "generate"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "verify-certificate-chain", name: "Verify Certificate Chain",
            description: "Verify a certificate against a CA bundle", category: "openssl",
            commandTemplate: "openssl verify -CAfile {{ca_file}} {{cert_file}}",
            parameters: [
                CommandParameter(name: "ca_file", label: "CA bundle file"),
                CommandParameter(name: "cert_file", label: "Certificate file"),
            ],
            tags: ["openssl", "certificate", "verify"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "convert-pem-to-pfx", name: "Convert PEM to PFX",
            description: "Bundle a certificate and private key into a PKCS#12 file", category: "openssl",
            commandTemplate: "openssl pkcs12 -export -out {{output_file}} -inkey {{key_file}} -in {{cert_file}}",
            parameters: [
                CommandParameter(name: "output_file", label: "Output file", defaultValue: "bundle.pfx"),
                CommandParameter(name: "key_file", label: "Key file"),
                CommandParameter(name: "cert_file", label: "Certificate file"),
            ],
            tags: ["openssl", "certificate", "convert"], risk: .readOnly
        ),
    ]

    // MARK: Terraform

    private static let terraform: [DevOpsCommand] = [
        DevOpsCommand(
            id: "plan-changes", name: "Plan Changes",
            description: "Preview infrastructure changes without applying them", category: "terraform",
            commandTemplate: "terraform plan -var-file={{var_file}}",
            parameters: [CommandParameter(name: "var_file", label: "Var file", defaultValue: "prod.tfvars")],
            tags: ["terraform", "plan"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "apply-changes", name: "Apply Changes",
            description: "Apply planned infrastructure changes", category: "terraform",
            commandTemplate: "terraform apply -var-file={{var_file}}",
            parameters: [CommandParameter(name: "var_file", label: "Var file", defaultValue: "prod.tfvars")],
            tags: ["terraform", "apply"], risk: .potentiallyDisruptive
        ),
        DevOpsCommand(
            id: "show-state", name: "Show State",
            description: "Print the current Terraform state", category: "terraform",
            commandTemplate: "terraform show",
            tags: ["terraform", "state"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "destroy-target", name: "Destroy Target",
            description: "Destroy a single targeted resource/module", category: "terraform",
            commandTemplate: "terraform destroy -target={{target}}",
            parameters: [CommandParameter(name: "target", label: "Target address", defaultValue: "module.raas_prod")],
            tags: ["terraform", "destroy"], risk: .destructive
        ),
        DevOpsCommand(
            id: "import-resource", name: "Import Resource",
            description: "Bring an existing resource under Terraform management", category: "terraform",
            commandTemplate: "terraform import {{address}} {{id}}",
            parameters: [
                CommandParameter(name: "address", label: "Resource address"),
                CommandParameter(name: "id", label: "Resource ID"),
            ],
            tags: ["terraform", "import"], risk: .potentiallyDisruptive
        ),
        DevOpsCommand(
            id: "format-and-validate", name: "Format and Validate",
            description: "Reformat every .tf file and validate the configuration", category: "terraform",
            commandTemplate: "terraform fmt -recursive && terraform validate",
            tags: ["terraform", "lint"], risk: .readOnly
        ),
    ]

    // MARK: Helm

    private static let helm: [DevOpsCommand] = [
        DevOpsCommand(
            id: "list-releases", name: "List Releases",
            description: "List Helm releases in a namespace", category: "helm",
            commandTemplate: "helm list -n {{namespace}}",
            parameters: [CommandParameter(name: "namespace", label: "Namespace", kind: .select, configOptionsKey: "namespaces")],
            tags: ["helm", "releases"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "upgrade-release", name: "Upgrade Release",
            description: "Upgrade (or install) a Helm release with new values", category: "helm",
            commandTemplate: "helm upgrade {{release}} {{chart}} -n {{namespace}} -f {{values_file}}",
            parameters: [
                CommandParameter(name: "release", label: "Release name"),
                CommandParameter(name: "chart", label: "Chart"),
                CommandParameter(name: "namespace", label: "Namespace", kind: .select, configOptionsKey: "namespaces"),
                CommandParameter(name: "values_file", label: "Values file", defaultValue: "values.yaml"),
            ],
            tags: ["helm", "upgrade"], risk: .potentiallyDisruptive
        ),
        DevOpsCommand(
            id: "rollback-release", name: "Rollback Release",
            description: "Roll a release back to a previous revision", category: "helm",
            commandTemplate: "helm rollback {{release}} {{revision}} -n {{namespace}}",
            parameters: [
                CommandParameter(name: "release", label: "Release name"),
                CommandParameter(name: "revision", label: "Revision", kind: .number),
                CommandParameter(name: "namespace", label: "Namespace", kind: .select, configOptionsKey: "namespaces"),
            ],
            tags: ["helm", "rollback"], risk: .potentiallyDisruptive
        ),
        DevOpsCommand(
            id: "show-release-values", name: "Show Release Values",
            description: "Print the currently deployed values for a release", category: "helm",
            commandTemplate: "helm get values {{release}} -n {{namespace}}",
            parameters: [
                CommandParameter(name: "release", label: "Release name"),
                CommandParameter(name: "namespace", label: "Namespace", kind: .select, configOptionsKey: "namespaces"),
            ],
            tags: ["helm", "values"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "uninstall-release", name: "Uninstall Release",
            description: "Uninstall a Helm release and delete its resources", category: "helm",
            commandTemplate: "helm uninstall {{release}} -n {{namespace}}",
            parameters: [
                CommandParameter(name: "release", label: "Release name"),
                CommandParameter(name: "namespace", label: "Namespace", kind: .select, configOptionsKey: "namespaces"),
            ],
            tags: ["helm", "uninstall"], risk: .destructive
        ),
    ]

    // MARK: ArgoCD

    private static let argocd: [DevOpsCommand] = [
        DevOpsCommand(
            id: "sync-application", name: "Sync Application",
            description: "Sync an ArgoCD application to its target state", category: "argocd",
            commandTemplate: "argocd app sync {{app_name}}",
            parameters: [CommandParameter(name: "app_name", label: "Application name")],
            tags: ["argocd", "sync"], risk: .potentiallyDisruptive
        ),
        DevOpsCommand(
            id: "get-application-status", name: "Get Application Status",
            description: "Show an application's sync/health status", category: "argocd",
            commandTemplate: "argocd app get {{app_name}}",
            parameters: [CommandParameter(name: "app_name", label: "Application name")],
            tags: ["argocd", "status"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "diff-application", name: "Diff Application",
            description: "Show the diff between live and desired manifests", category: "argocd",
            commandTemplate: "argocd app diff {{app_name}}",
            parameters: [CommandParameter(name: "app_name", label: "Application name")],
            tags: ["argocd", "diff"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "rollback-application", name: "Rollback Application",
            description: "Roll an application back to a previous deployed revision", category: "argocd",
            commandTemplate: "argocd app rollback {{app_name}} {{revision}}",
            parameters: [
                CommandParameter(name: "app_name", label: "Application name"),
                CommandParameter(name: "revision", label: "Revision"),
            ],
            tags: ["argocd", "rollback"], risk: .potentiallyDisruptive
        ),
        DevOpsCommand(
            id: "list-applications", name: "List Applications",
            description: "List every ArgoCD application and its status", category: "argocd",
            commandTemplate: "argocd app list",
            tags: ["argocd", "list"], risk: .readOnly
        ),
    ]

    // MARK: Jenkins

    private static let jenkins: [DevOpsCommand] = [
        DevOpsCommand(
            id: "trigger-build", name: "Trigger Build",
            description: "Trigger a Jenkins job build via its REST API", category: "jenkins",
            commandTemplate: "curl -X POST {{jenkins_url}}/job/{{job_name}}/build --user {{user}}:{{api_token}}",
            parameters: [
                CommandParameter(name: "jenkins_url", label: "Jenkins URL"),
                CommandParameter(name: "job_name", label: "Job name"),
                CommandParameter(name: "user", label: "User"),
                CommandParameter(name: "api_token", label: "API token"),
            ],
            tags: ["jenkins", "build"], risk: .potentiallyDisruptive
        ),
        DevOpsCommand(
            id: "get-build-console-output", name: "Get Build Console Output",
            description: "Fetch the console log for a specific build", category: "jenkins",
            commandTemplate: "curl -s {{jenkins_url}}/job/{{job_name}}/{{build_number}}/consoleText --user {{user}}:{{api_token}}",
            parameters: [
                CommandParameter(name: "jenkins_url", label: "Jenkins URL"),
                CommandParameter(name: "job_name", label: "Job name"),
                CommandParameter(name: "build_number", label: "Build number", kind: .number),
                CommandParameter(name: "user", label: "User"),
                CommandParameter(name: "api_token", label: "API token"),
            ],
            tags: ["jenkins", "logs"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "list-jobs-cli", name: "List Jobs (CLI)",
            description: "List every job via the Jenkins CLI jar", category: "jenkins",
            commandTemplate: "java -jar jenkins-cli.jar -s {{jenkins_url}} list-jobs",
            parameters: [CommandParameter(name: "jenkins_url", label: "Jenkins URL")],
            tags: ["jenkins", "cli"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "restart-jenkins-safely", name: "Restart Jenkins Safely",
            description: "Restart Jenkins once no jobs are running", category: "jenkins",
            commandTemplate: "java -jar jenkins-cli.jar -s {{jenkins_url}} safe-restart",
            parameters: [CommandParameter(name: "jenkins_url", label: "Jenkins URL")],
            tags: ["jenkins", "restart"], risk: .potentiallyDisruptive
        ),
    ]

    // MARK: General DevOps

    private static let general: [DevOpsCommand] = [
        DevOpsCommand(
            id: "check-process-by-port", name: "Check Process by Port",
            description: "Find which process is listening on a local port", category: "general",
            commandTemplate: "lsof -i :{{port}}",
            parameters: [CommandParameter(name: "port", label: "Port", kind: .number, defaultValue: "8080")],
            tags: ["process", "port"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "kill-process-by-pid", name: "Kill Process by PID",
            description: "Force-kill a process by its process id", category: "general",
            commandTemplate: "kill -9 {{pid}}",
            parameters: [CommandParameter(name: "pid", label: "PID", kind: .number)],
            tags: ["process", "kill"], risk: .destructive
        ),
        DevOpsCommand(
            id: "watch-a-command", name: "Watch a Command",
            description: "Re-run a command on an interval and show the output", category: "general",
            commandTemplate: "watch -n {{interval}} '{{command}}'",
            parameters: [
                CommandParameter(name: "interval", label: "Interval (seconds)", kind: .number, defaultValue: "2"),
                CommandParameter(name: "command", label: "Command", kind: .textarea, defaultValue: "kubectl get pods"),
            ],
            tags: ["watch", "monitoring"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "search-text-in-files", name: "Search Text in Files",
            description: "Recursively search files for a pattern with line numbers", category: "general",
            commandTemplate: "grep -rn \"{{pattern}}\" {{path}}",
            parameters: [
                CommandParameter(name: "pattern", label: "Pattern"),
                CommandParameter(name: "path", label: "Path", defaultValue: "."),
            ],
            tags: ["search", "grep"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "compress-directory", name: "Compress Directory",
            description: "Create a gzip-compressed tarball of a directory", category: "general",
            commandTemplate: "tar -czvf {{output_file}}.tar.gz {{directory}}",
            parameters: [
                CommandParameter(name: "output_file", label: "Output file (no extension)", defaultValue: "archive"),
                CommandParameter(name: "directory", label: "Directory"),
            ],
            tags: ["archive", "tar"], risk: .readOnly
        ),
        DevOpsCommand(
            id: "sync-directories", name: "Sync Directories",
            description: "Sync one directory's contents into another", category: "general",
            commandTemplate: "rsync -avz {{source}}/ {{destination}}/",
            parameters: [
                CommandParameter(name: "source", label: "Source"),
                CommandParameter(name: "destination", label: "Destination"),
            ],
            tags: ["rsync", "sync"], risk: .potentiallyDisruptive
        ),
    ]
}
