#!/bin/bash

#=================================================
# CHECKING
#=================================================

CHECK_USER () {	# Vérifie la validité de l'user admin
# $1 = Variable de l'user admin.
	ynh_user_exists "$1" || ynh_die "Wrong user"
}

CHECK_DOMAINPATH () {	# Vérifie la disponibilité du path et du domaine.
	sudo yunohost app checkurl $domain$path_url -a $app
}

CHECK_FINALPATH () {	# Vérifie que le dossier de destination n'est pas déjà utilisé.
	final_path=/var/www/$app
	test ! -e "$final_path" || ynh_die "This path already contains a folder"
}

#=================================================
# DISPLAYING
#=================================================

NO_PRINT () {	# Supprime l'affichage dans stdout pour la commande en argument.
	set +x
	$@
	set -x
}

WARNING () {	# Écrit sur le canal d'erreur pour passer en warning.
	$@ >&2
}

SUPPRESS_WARNING () {	# Force l'écriture sur la sortie standard
	$@ 2>&1
}

QUIET () {	# Redirige la sortie standard dans /dev/null
	$@ > /dev/null
}

ALL_QUIET () {	# Redirige la sortie standard et d'erreur dans /dev/null
	$@ > /dev/null 2>&1
}

#=================================================
# SETUP
#=================================================

SETUP_SOURCE () {	# Télécharge la source, décompresse et copie dans $final_path
	src_url=$(cat ../conf/app.src | grep SOURCE_URL | cut -d'>' -f2)
	src_checksum=$(cat ../conf/app.src | grep SOURCE_SUM | cut -d= -f2)
	# Download sources from the upstream
	wget -nv -O source.tar.gz $src_url
	# Vérifie la somme de contrôle de la source téléchargée.
	echo "$src_checksum source.tar.gz" | md5sum -c --status || ynh_die "Corrupt source"
	# Extract source into the app dir
	sudo mkdir -p $final_path
	sudo tar -x -f source.tar.gz -C $final_path --strip-components 1
	# Copie les fichiers additionnels ou modifiés.
	if test -e "../sources/ajouts"; then
		sudo cp -a ../sources/ajouts/. "$final_path"
	fi
}

SETUP_SOURCE_ZIP () {	# Télécharge la source, décompresse et copie dans $final_path
# Attention l'archive /tmp/xxx/mytinytodo/*
	src_url=$(cat ../conf/app.src | grep SOURCE_URL | cut -d'>' -f2)
	src_checksum=$(cat ../conf/app.src | grep SOURCE_SUM | cut -d= -f2)
	# Download sources from the upstream
	wget -nv -O source.zip $src_url
	# Vérifie la somme de contrôle de la source téléchargée.
	echo "$src_checksum source.zip" | md5sum -c --status || ynh_die "Corrupt source"
	# Extract source into the app dir
	sudo mkdir -p $final_path
	temp_dir=$(mktemp -d)
	unzip -quo source.zip -d $temp_dir	# On passe par un dossier temporaire car unzip ne permet pas d'ignorer le dossier parent.
	sudo cp -a $temp_dir/*/. $final_path
	sudo rm -r $temp_dir
	# Copie les fichiers additionnels ou modifiés.
	if test -e "../sources/ajouts"; then
		sudo cp -a ../sources/ajouts/. "$final_path"
	fi
}

UPDATE_SOURCE_ZIP () {	# Télécharge la source, décompresse et copie dans $final_path
# Attention dans l'update le zip /tmp/xxx/db je n'ai pas respecte l'arboresence 
# il n'y a pas de repertoire principal mytinytodo, la commande cp est differente
	upd_url=$(cat ../conf/app.src | grep UPDATE_URL | cut -d'|' -f2)
	upd_checksum=$(cat ../conf/app.src | grep UPDATE_SUM | cut -d'@' -f2)
	# Download sources from the upstream
	wget -nv -O source.zip $upd_url
	# Vérifie la somme de contrôle de la source téléchargée.
	echo "$upd_checksum source.zip" | md5sum -c --status || ynh_die "Corrupt source"
	# Extract source into the app dir
	sudo mkdir -p $final_path
	temp_dir=$(mktemp -d)
	unzip -quo source.zip -d $temp_dir	# On passe par un dossier temporaire car unzip ne permet pas d'ignorer le dossier parent.
	sudo cp -a $temp_dir/* $final_path
	sudo rm -r $temp_dir
	# Copie les fichiers additionnels ou modifiés.
	if test -e "../sources/ajouts"; then
		sudo cp -a ../sources/ajouts/. "$final_path"
	fi
}

POOL_FPM () {	# Créer le fichier de configuration du pool php-fpm et le configure.
	sed -i "s@__NAMETOCHANGE__@$app@g" ../conf/php-fpm.conf
	sed -i "s@__FINALPATH__@$final_path@g" ../conf/php-fpm.conf
	sed -i "s@__USER__@$app@g" ../conf/php-fpm.conf
	finalphpconf=/etc/php5/fpm/pool.d/$app.conf
	sudo cp ../conf/php-fpm.conf $finalphpconf
	sudo chown root: $finalphpconf
	finalphpini=/etc/php5/fpm/conf.d/20-$app.ini
	sudo cp ../conf/php-fpm.ini $finalphpini
	sudo chown root: $finalphpini
	sudo systemctl reload php5-fpm
}

YNH_CURL () {
	data_post=$1
	url_access=$2
	sleep 1
	curl -kL -H "Host: $domain" --resolve $domain:443:127.0.0.1 --data "$data_post" "https://localhost$path_url$url_access" 2>&1
}

#=================================================
# REMOVE
#=================================================

REMOVE_NGINX_CONF () {	# Suppression de la configuration nginx
	if [ -e "/etc/nginx/conf.d/$domain.d/$app.conf" ]; then	# Delete nginx config
		echo "Delete nginx config"
		sudo rm "/etc/nginx/conf.d/$domain.d/$app.conf"
		sudo systemctl reload nginx
	fi
}

REMOVE_FPM_CONF () {	# Suppression de la configuration du pool php-fpm
	if [ -e "/etc/php5/fpm/pool.d/$app.conf" ]; then	# Delete fpm config
		echo "Delete fpm config"
		sudo rm "/etc/php5/fpm/pool.d/$app.conf"
	fi
	if [ -e "/etc/php5/fpm/conf.d/20-$app.ini" ]; then	# Delete php config
		echo "Delete php config"
		sudo rm "/etc/php5/fpm/conf.d/20-$app.ini"
	fi
	sudo systemctl reload php5-fpm
}

SECURE_REMOVE () {      # Suppression de dossier avec vérification des variables
	chaine="$1"	# L'argument doit être donné entre quotes simple '', pour éviter d'interpréter les variables.
	no_var=0
	while (echo "$chaine" | grep -q '\$')	# Boucle tant qu'il y a des $ dans la chaine
	do
		no_var=1
		global_var=$(echo "$chaine" | cut -d '$' -f 2)	# Isole la première variable trouvée.
		only_var=\$$(expr "$global_var" : '\([A-Za-z0-9_]*\)')	# Isole complètement la variable en ajoutant le $ au début et en gardant uniquement le nom de la variable. Se débarrasse surtout du / et d'un éventuel chemin derrière.
		real_var=$(eval "echo ${only_var}")		# `eval "echo ${var}` permet d'interpréter une variable contenue dans une variable.
		if test -z "$real_var" || [ "$real_var" = "/" ]; then
			WARNING echo "Variable $only_var is empty, suppression of $chaine cancelled."
			return 1
		fi
		chaine=$(echo "$chaine" | sed "s@$only_var@$real_var@")	# remplace la variable par sa valeur dans la chaine.
	done
	if [ "$no_var" -eq 1 ]
	then
		if [ -e "$chaine" ]; then
			echo "Delete directory $chaine"
			sudo rm -r "$chaine"
		fi
		return 0
	else
		WARNING echo "No detected variable."
		return 1
	fi
}

#=================================================
# BACKUP
#=================================================

BACKUP_FAIL_UPGRADE () {
	WARNING echo "Upgrade failed."
	app_bck=${app//_/-}	# Replace all '_' by '-'
	if sudo yunohost backup list | grep -q $app_bck-pre-upgrade$backup_number; then	# Vérifie l'existence de l'archive avant de supprimer l'application et de restaurer
		sudo yunohost app remove $app	# Supprime l'application avant de la restaurer.
		sudo yunohost backup restore --ignore-hooks $app_bck-pre-upgrade$backup_number --apps $app --force	# Restore the backup if upgrade failed
		ynh_die "The app was restored to the way it was before the failed upgrade."
	fi
}

BACKUP_BEFORE_UPGRADE () {	# Backup the current version of the app, restore it if the upgrade fails
	backup_number=1
	old_backup_number=2
	app_bck=${app//_/-}	# Replace all '_' by '-'
	if sudo yunohost backup list | grep -q $app_bck-pre-upgrade1; then	# Vérifie l'existence d'une archive déjà numéroté à 1.
		backup_number=2	# Et passe le numéro de l'archive à 2
		old_backup_number=1
	fi

	sudo yunohost backup create --ignore-hooks --apps $app --name $app_bck-pre-upgrade$backup_number	# Créer un backup différent de celui existant.
	if [ "$?" -eq 0 ]; then	# Si le backup est un succès, supprime l'archive précédente.
		if sudo yunohost backup list | grep -q $app_bck-pre-upgrade$old_backup_number; then	# Vérifie l'existence de l'ancienne archive avant de la supprimer, pour éviter une erreur.
			QUIET sudo yunohost backup delete $app_bck-pre-upgrade$old_backup_number
		fi
	else	# Si le backup a échoué
		ynh_die "Backup failed, the upgrade process was aborted."
	fi
}

HUMAN_SIZE () {	# Transforme une taille en Ko en une taille lisible pour un humain
	human=$(numfmt --to=iec --from-unit=1K $1)
	echo $human
}

CHECK_SIZE () {	# Vérifie avant chaque backup que l'espace est suffisant
	file_to_analyse=$1
	backup_size=$(sudo du --summarize "$file_to_analyse" | cut -f1)
	free_space=$(sudo df --output=avail "/home/yunohost.backup" | sed 1d)

	if [ $free_space -le $backup_size ]
	then
		WARNING echo "Espace insuffisant pour sauvegarder $file_to_analyse."
		WARNING echo "Espace disponible: $(HUMAN_SIZE $free_space)"
		ynh_die "Espace nécessaire: $(HUMAN_SIZE $backup_size)"
	fi
}

#=================================================
# CONFIGURATION
#=================================================

STORE_MD5_CONFIG () {	# Enregistre la somme de contrôle du fichier de config
# $1 = Nom du fichier de conf pour le stockage dans settings.yml
# $2 = Nom complet et chemin du fichier de conf.
	ynh_app_setting_set $app $1_file_md5 $(sudo md5sum "$2" | cut -d' ' -f1)
}

CHECK_MD5_CONFIG () {	# Créé un backup du fichier de config si il a été modifié.
# $1 = Nom du fichier de conf pour le stockage dans settings.yml
# $2 = Nom complet et chemin du fichier de conf.
	if [ "$(ynh_app_setting_get $app $1_file_md5)" != $(sudo md5sum "$2" | cut -d' ' -f1) ]; then
		sudo cp -a "$2" "$2.backup.$(date '+%d.%m.%y_%Hh%M,%Ss')"	# Si le fichier de config a été modifié, créer un backup.
	fi
}

#=================================================
# PACKAGE CHECK BYPASSING...
#=================================================

IS_PACKAGE_CHECK () {	# Détermine une exécution en conteneur (Non testé)
	return uname -n | grep -c 'pchecker_lxc'
}

#=================================================
#=================================================
# FUTUR YNH HELPERS
#=================================================
# Importer ce fichier de fonction avant celui des helpers officiel
# Ainsi, les officiels prendront le pas sur ceux-ci le cas échéant
#=================================================

# Ignore the yunohost-cli log to prevent errors with conditionals commands
# usage: ynh_no_log COMMAND
# Simply duplicate the log, execute the yunohost command and replace the log without the result of this command
# It's a very badly hack...
ynh_no_log() {
  ynh_cli_log=/var/log/yunohost/yunohost-cli.log
  sudo cp -a ${ynh_cli_log} ${ynh_cli_log}-move
  eval $@
  ext_code=$?
  sudo mv ${ynh_cli_log}-move ${ynh_cli_log}
  return $?
}

# Normalize the url path syntax
# Handle the slash at the beginning of path and its absence at ending
# Return a normalized url path
#
# example: url_path=$(ynh_normalize_url_path $url_path)
#          ynh_normalize_url_path example -> /example
#          ynh_normalize_url_path /example -> /example
#          ynh_normalize_url_path /example/ -> /example
#
# usage: ynh_normalize_url_path path_to_normalize
# | arg: url_path_to_normalize - URL path to normalize before using it
ynh_normalize_url_path () {
	path_url=$1
	test -n "$path_url" || ynh_die "ynh_normalize_url_path expect a URL path as first argument and received nothing."
	if [ "${path_url:0:1}" != "/" ]; then    # If the first character is not a /
		path_url="/$path_url"    # Add / at begin of path variable
	fi
	if [ "${path_url:${#path_url}-1}" == "/" ] && [ ${#path_url} -gt 1 ]; then    # If the last character is a / and that not the only character.
		path_url="${path_url:0:${#path_url}-1}"	# Delete the last character
	fi
	echo $path_url
}

# Create a database, an user and its password. Then store the password in the app's config
#
# User of database will be store in db_user's variable.
# Name of database will be store in db_name's variable.
# And password in db_pwd's variable.
#
# usage: ynh_mysql_generate_db user name
# | arg: user - Owner of the database
# | arg: name - Name of the database
ynh_mysql_generate_db () {
	db_pwd=$(ynh_string_random)	# Generate a random password
	ynh_mysql_create_db "$2" "$1" "$db_pwd"	# Create the database
	ynh_app_setting_set $app mysqlpwd $db_pwd	# Store the password in the app's config
}

# Remove a database if it exist and the associated user
#
# usage: ynh_mysql_remove_db user name
# | arg: user - Proprietary of the database
# | arg: name - Name of the database
ynh_mysql_remove_db () {
	if mysqlshow -u root -p$(sudo cat $MYSQL_ROOT_PWD_FILE) | grep -q "^| $2"; then	# Check if the database exist
		echo "Remove database $2" >&2
		ynh_mysql_drop_db $2	# Remove the database
		ynh_mysql_drop_user $1	# Remove the associated user to database
	else
		echo "Database $2 not found" >&2
	fi
}

# Correct the name given in argument for mariadb
#
# Avoid invalid name for your database
#
# Exemple: dbname=$(ynh_make_valid_dbid $app)
#
# usage: ynh_make_valid_dbid name
# | arg: name - name to correct
# | ret: the corrected name
ynh_make_valid_dbid () {
	dbid=${1//[-.]/_}	# Mariadb doesn't support - and . in the name of databases. It will be replace by _
	echo $dbid
}

# Manage a fail of the script
#
# Print a warning to inform that the script was failed
# Execute the ynh_clean_setup function if used in the app script
#
# usage of ynh_clean_setup function
# This function provide a way to clean some residual of installation that not managed by remove script.
# To use it, simply add in your script:
# ynh_clean_setup () {
#        instructions...
# }
# This function is optionnal.
#
# Usage: ynh_exit_properly is used only by the helper ynh_check_error.
# You must not use it directly.
ynh_exit_properly () {
	ext_code=$?
	if [ "$ext_code" -eq 0 ]; then
			exit 0	# Exit without error if the script ended correctly
	fi

	trap '' EXIT	# Ignore new exit signals
	set +eu	# Do not exit anymore if a command fail or if a variable is empty

	echo -e "!!\n  $app's script has encountered an error. Its execution was cancelled.\n!!" >&2

	if type -t ynh_clean_setup > /dev/null; then	# Check if the function exist in the app script.
		ynh_clean_setup	# Call the function to do specific cleaning for the app.
	fi

	ynh_die	# Exit with error status
}

# Exit if an error occurs during the execution of the script.
#
# Stop immediatly the execution if an error occured or if a empty variable is used.
# The execution of the script is derivate to ynh_exit_properly function before exit.
#
# Usage: ynh_abort_if_errors
ynh_abort_if_errors () {
	set -eu	# Exit if a command fail, and if a variable is used unset.
	trap ynh_exit_properly EXIT	# Capturing exit signals on shell script
}

# Install dependencies with a equivs control file
#
# usage: ynh_install_app_dependencies dep [dep [...]]
# | arg: dep - the package name to install in dependence
ynh_install_app_dependencies () {
    dependencies=$@
    manifest_path="../manifest.json"
    if [ ! -e "$manifest_path" ]; then
    	manifest_path="../settings/manifest.json"	# Into the restore script, the manifest is not at the same place
    fi
    version=$(sudo python3 -c "import sys, json;print(json.load(open(\"$manifest_path\"))['version'])")	# Retrieve the version number in the manifest file.
    dep_app=${app//_/-}	# Replace all '_' by '-'

    if ynh_package_is_installed "${dep_app}-ynh-deps"; then
		echo "A package named ${dep_app}-ynh-deps is already installed" >&2
    else
		cat > ./${dep_app}-ynh-deps.control << EOF	# Make a control file for equivs-build
Section: misc
Priority: optional
Package: ${dep_app}-ynh-deps
Version: ${version}
Depends: ${dependencies// /, }
Architecture: all
Description: Fake package for ${app} (YunoHost app) dependencies
 This meta-package is only responsible of installing its dependencies.
EOF
		ynh_package_install_from_equivs ./${dep_app}-ynh-deps.control \
			|| ynh_die "Unable to install dependencies"	# Install the fake package and its dependencies
		ynh_app_setting_set $app apt_dependencies $dependencies
	fi
}

# Remove fake package and its dependencies
#
# Dependencies will removed only if no other package need them.
#
# usage: ynh_remove_app_dependencies
ynh_remove_app_dependencies () {
    dep_app=${app//_/-}	# Replace all '_' by '-'
    ynh_package_autoremove ${dep_app}-ynh-deps	# Remove the fake package and its dependencies if they not still used.
}

# Use logrotate to manage the logfile
#
# usage: ynh_use_logrotate [logfile]
# | arg: logfile - absolute path of logfile
#
# If no argument provided, a standard directory will be use. /var/log/${app}
# You can provide a path with the directory only or with the logfile.
# /parentdir/logdir/
# /parentdir/logdir/logfile.log
#
# It's possible to use this helper several times, each config will added to same logrotate config file.
ynh_use_logrotate () {
	if [ "$#" -gt 0 ]; then
		if [ "$(echo ${1##*.})" == "log" ]; then	# Keep only the extension to check if it's a logfile
			logfile=$1	# In this case, focus logrotate on the logfile
		else
			logfile=$1/.log	# Else, uses the directory and all logfile into it.
		fi
	else
		logfile="/var/log/${app}/.log" # Without argument, use a defaut directory in /var/log
	fi
	cat > ./${app}-logrotate << EOF	# Build a config file for logrotate
$logfile {
		# Rotate if the logfile exceeds 100Mo
	size 100M
		# Keep 12 old log maximum
	rotate 12
		# Compress the logs with gzip
	compress
		# Compress the log at the next cycle. So keep always 2 non compressed logs
	delaycompress
		# Copy and truncate the log to allow to continue write on it. Instead of move the log.
	copytruncate
		# Do not do an error if the log is missing
	missingok
		# Not rotate if the log is empty
	notifempty
		# Keep old logs in the same dir
	noolddir
}
EOF
	sudo mkdir -p $(dirname "$logfile")	# Create the log directory, if not exist
	cat ${app}-logrotate | sudo tee -a /etc/logrotate.d/$app > /dev/null	# Append this config to the others for this app. If a config file already exist
}

# Remove the app's logrotate config.
#
# usage: ynh_remove_logrotate
ynh_remove_logrotate () {
	if [ -e "/etc/logrotate.d/$app" ]; then
		sudo rm "/etc/logrotate.d/$app"
	fi
}

# Find a free port and return it
#
# example: port=$(ynh_find_port 8080)
#
# usage: ynh_find_port begin_port
# | arg: begin_port - port to start to search
ynh_find_port () {
	port=$1
	test -n "$port" || ynh_die "The argument of ynh_find_port must be a valid port."
	while netcat -z 127.0.0.1 $port       # Check if the port is free
	do
		port=$((port+1))	# Else, pass to next port
	done
	echo $port
}

# Create a system user
#
# usage: ynh_system_user_create user_name [home_dir]
# | arg: user_name - Name of the system user that will be create
# | arg: home_dir - Path of the home dir for the user. Usually the final path of the app. If this argument is omitted, the user will be created without home
ynh_system_user_create () {
	if ! ynh_system_user_exists "$1"	# Check if the user exists on the system
	then	# If the user doesn't exist
		if [ $# -ge 2 ]; then	# If a home dir is mentioned
			user_home_dir="-d $2"
		else
			user_home_dir="--no-create-home"
		fi
		sudo useradd $user_home_dir --system --user-group $1 --shell /usr/sbin/nologin || ynh_die "Unable to create $1 system account"
	fi
}

# Delete a system user
#
# usage: ynh_system_user_delete user_name
# | arg: user_name - Name of the system user that will be create
ynh_system_user_delete () {
    if ynh_system_user_exists "$1"	# Check if the user exists on the system
    then
		echo "Remove the user $1" >&2
		sudo userdel $1
	else
		echo "The user $1 was not found" >&2
    fi
}
