#!/bin/bash
set -e

echo step1...

if docker compose version >/dev/null 2>&1; then
    docker compose up -d
elif docker-compose version >/dev/null 2>&1; then
    docker-compose up -d
fi

echo step2...

until curl -s --head --request GET http://localhost:8000/users/sign_in | grep -q "200 OK"
do
    echo waiting for gitlab...
    sleep 3
done

echo step3...

cat <<EOFF | docker exec -i gitlab-server-1 bash
cat > /tmp/post-reconfigure.sh << EOF
#!/bin/bash
set -e

gitlab-rails runner - <<EOS

if user = User.find_by_username('root')
    token = user.personal_access_tokens.find_by(name: 'API')
    if !token || token.expired? 
        token = user.personal_access_tokens.create(
            scopes: ['api', 'admin_mode'],
            name: 'API',
            expires_at: PersonalAccessToken::MAX_PERSONAL_ACCESS_TOKEN_LIFETIME_IN_DAYS.days.from_now
        )
        token.save!
        token_value = token.token
        File.open('/tmp/root.pat', 'w', 0600) { |file| file.write(token_value) }
        puts "PAT written to /tmp/root.pat"
    else
        puts "There is already a PAT with the name 'API' which expires at #{token.expires_at}."
    end
end

EOS
EOF

chmod +x /tmp/post-reconfigure.sh
/tmp/post-reconfigure.sh
EOFF

echo step4...

docker exec -i gitlab-server-1 cat /tmp/root.pat > root.pat
PAT=$(cat root.pat)
echo $PAT

echo step5...

RUNNER_TOKEN=$(curl --silent --request POST --url "http://localhost:8000/api/v4/user/runners" \
--data "runner_type=instance_type" \
--data "description=runner-1" \
--header "PRIVATE-TOKEN: $PAT" | jq -r '.token')
echo $RUNNER_TOKEN

echo step6...

until (docker exec -i gitlab-runner-1 ps -ef) | grep -q "gitlab-runner run"
do
    echo waiting...
    sleep 3
done

echo step7...

cat <<EOFF | docker exec -i gitlab-runner-1 bash
gitlab-runner register \
--non-interactive \
--name=runner-1 \
--url="http://gitlab-server-1:8000" \
--token="$RUNNER_TOKEN" \
--executor="shell"
EOFF

echo step8...

until curl -s --head --request GET http://localhost:8080/ui/login/ | grep -q "200 OK"
do
    echo waiting for artifactory...
    sleep 3
done

curl -X POST -u admin:password -H "Content-type: application/json" -d '{ "userName" : "admin", "oldPassword" : "password", "newPassword1" : "f0ll0wth3whit3raBB1t!!", "newPassword2" : "f0ll0wth3whit3raBB1t!!" }' http://localhost:8081/artifactory/api/security/users/authorization/changePassword

echo finished