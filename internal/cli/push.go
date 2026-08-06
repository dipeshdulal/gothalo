package cli

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/spf13/cobra"

	"github.com/dipeshdulal/gothalo/internal/config"
	"github.com/dipeshdulal/gothalo/internal/push"
)

func newPushCmd() *cobra.Command {
	var configPath, project string

	cmd := &cobra.Command{
		Use:   "push",
		Short: "Set up and check FCM push credentials",
		Long: "Set up and check the credentials gothalo uses to send push notifications.\n\n" +
			"`login` authenticates you as yourself through gcloud, so a team can share one\n" +
			"Firebase project without anyone copying a service-account key around. Each\n" +
			"person's access is then granted and revoked individually in IAM.",
	}
	cmd.PersistentFlags().StringVarP(&configPath, "config", "c", "", "path to config file (default ~/.gothalo/config.json)")
	cmd.PersistentFlags().StringVarP(&project, "project", "p", "", "Firebase project id (default: push.project_id from config)")

	cmd.AddCommand(
		&cobra.Command{
			Use:   "login",
			Short: "Authenticate to FCM as yourself via gcloud (no key file to share)",
			RunE: func(cmd *cobra.Command, args []string) error {
				return runPushLogin(configPath, project)
			},
		},
		&cobra.Command{
			Use:   "status",
			Short: "Show which credentials are in use and whether they can send",
			RunE: func(cmd *cobra.Command, args []string) error {
				return runPushStatus(configPath, project)
			},
		},
	)
	return cmd
}

// resolveProject settles which Firebase project to target: the flag, else the
// stored config. It stays empty for a service-account file, which names its own.
func resolveProject(cfg *config.Config, flag string) string {
	if flag != "" {
		return flag
	}
	return cfg.Push.ProjectID
}

func runPushLogin(configPath, projectFlag string) error {
	cfg, err := config.Load(configPath)
	if err != nil {
		return err
	}
	project := resolveProject(cfg, projectFlag)
	if project == "" {
		return errors.New("which Firebase project? pass --project <id> (once — it is saved to config)")
	}

	gcloud, err := exec.LookPath("gcloud")
	if err != nil {
		return fmt.Errorf("gcloud not found on PATH — install the Google Cloud CLI " +
			"(https://cloud.google.com/sdk/docs/install), then re-run `gothalo push login`")
	}

	// --scopes REPLACES gcloud's default set, so firebase.messaging has to be
	// listed explicitly; a token minted without it fails later with a 403 that
	// looks like a permissions problem rather than a scope problem. Passing this
	// correctly is most of what this command exists to do.
	scopes := strings.Join(push.LoginScopes, ",")
	fmt.Println(titleStyle.Render("Opening your browser to authenticate with Google…"))
	fmt.Println(hintStyle.Render("  scopes: " + scopes))
	fmt.Println()

	c := exec.Command(gcloud, "auth", "application-default", "login", "--scopes="+scopes)
	c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
	if err := c.Run(); err != nil {
		return fmt.Errorf("gcloud login failed: %w", err)
	}

	// Persist the project so `serve` and `status` need no flag. User credentials
	// name a person, not a project, so without this the credential alone is not
	// enough to address a send.
	if cfg.Push.ProjectID != project {
		cfg.Push.ProjectID = project
		if err := cfg.Save(); err != nil {
			return fmt.Errorf("save project id to config: %w", err)
		}
		fmt.Println(hintStyle.Render("saved push.project_id=" + project + " to " + cfg.ConfigPath()))
	}
	fmt.Println()

	return reportPushStatus(cfg, project)
}

func runPushStatus(configPath, projectFlag string) error {
	cfg, err := config.Load(configPath)
	if err != nil {
		return err
	}
	return reportPushStatus(cfg, resolveProject(cfg, projectFlag))
}

// reportPushStatus prints what credentials resolved and whether they can send.
// The verify step is the point: "credentials found" is not the question anyone
// actually has.
func reportPushStatus(cfg *config.Config, project string) error {
	client, err := push.Resolve(cfg.Push.ServiceAccountPath, project)
	if err != nil {
		switch {
		case errors.Is(err, push.ErrNoCredentials):
			fmt.Println(hintStyle.Render("no FCM credentials — push is disabled and notifications only log."))
			fmt.Println(hintStyle.Render("run `gothalo push login --project <firebase-project-id>` to authenticate as yourself."))
		case errors.Is(err, push.ErrNoProjectID):
			fmt.Println(hintStyle.Render("credentials found, but no Firebase project to send to."))
			fmt.Println(hintStyle.Render("pass --project <id>, or set push.project_id in " + cfg.ConfigPath()))
		}
		return err
	}

	fmt.Println(titleStyle.Render("FCM credentials"))
	printField("source", client.Source())
	printField("type", credentialLabel(client.Kind()))
	printField("project", client.ProjectID())
	if id := client.Identity(); id != "" {
		printField("identity", id)
	}
	fmt.Println()

	if err := client.Verify(); err != nil {
		if errors.Is(err, push.ErrPermissionDenied) {
			// The single most likely failure on the gcloud path, and the one a
			// user cannot fix alone — say who has to act.
			fmt.Println(hintStyle.Render("✗ authenticated, but not allowed to send to " + client.ProjectID()))
			fmt.Println(hintStyle.Render("  ask the project owner to grant you Firebase Cloud Messaging access."))
		} else {
			fmt.Println(hintStyle.Render("✗ cannot send"))
		}
		return err
	}
	fmt.Println(okStyle.Render("✓ can send to " + client.ProjectID()))
	return nil
}

func printField(k, v string) {
	fmt.Printf("  %s %s\n", idStyle.Render(fmt.Sprintf("%-9s", k)), v)
}

// credentialLabel spells out the security property of each shape, since that is
// the whole reason there is a choice.
func credentialLabel(kind string) string {
	switch kind {
	case "service_account":
		return "service account key (shared secret — revoke by rotating the key)"
	case "authorized_user":
		return "your Google account via gcloud (revoke in IAM, per person)"
	case "metadata":
		return "attached instance identity (no key material anywhere)"
	default:
		return kind
	}
}
