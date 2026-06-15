#include "game_logic.hpp"
#include "constants.hpp"

#include <functional>

#include <algorithm>
#include <cmath>
#include <cstdlib>

// Resets ball/player states and prepares the next kickoff.
void resetGame(Ball& ball, std::vector<Player>& team1, std::vector<Player>& team2, GameState& gameState, int scoringTeamSide) {
    ball.x = 0.0f;
    ball.y = 0.0f;
    ball.dx = 0.0f;
    ball.dy = 0.0f;
    ball.owner = nullptr;
    ball.isSuperShot = false;
    ball.chargingPower = 0.0f;
    ball.spinX = 0.0f;
    ball.spinY = 0.0f;
    ball.spinZ = 0.0f;
    ball.trailX.clear();
    ball.trailY.clear();

    for (auto& p : team1) {
        p.x = p.startX;
        p.y = p.startY;
        p.stunTimer = 0.0f;
        p.kickPower = 0.0f;
        p.isMoving = false;
        p.facingX = static_cast<float>(p.side);
        p.facingY = 0.0f;
    }
    for (auto& p : team2) {
        p.x = p.startX;
        p.y = p.startY;
        p.stunTimer = 0.0f;
        p.kickPower = 0.0f;
        p.isMoving = false;
        p.facingX = static_cast<float>(p.side);
        p.facingY = 0.0f;
    }

    if (scoringTeamSide == -1) {
        ball.owner = &team1[5];
    } else {
        ball.owner = &team2[5];
    }

    if (ball.owner) {
        ball.owner->x = 0.0f;
        ball.owner->y = 0.0f;
    }

    ball.x = 0.0f;
    ball.y = 0.0f;
    gameState.kickoffTimer = 2.0f;
}

// Advances ball physics, handles wall collisions, and detects goals.
int updateBall(Ball& ball, Score& score, std::vector<Player>& team1, std::vector<Player>& team2, GameState& gameState, float deltaTime) {
    using namespace Constants;

    if (ball.owner) {
        ball.x = ball.owner->x + (ball.owner->facingX * 0.035f);
        ball.y = ball.owner->y + (ball.owner->facingY * 0.035f);
        ball.dx = 0.0f;
        ball.dy = 0.0f;
        return 0;
    }

    float frameScale = deltaTime * 60.0f;
    ball.x += ball.dx * frameScale;
    ball.y += ball.dy * frameScale;
    float frictionScale = std::pow(ball.friction, frameScale);
    ball.dx *= frictionScale;
    ball.dy *= frictionScale;

    // Keep ball within field boundaries
    float ballRadius = 0.01f;
    bool hitLeftRight = false;
    bool hitTopBottom = false;
    
    if (ball.x > FIELD_BOUNDARY_X - ballRadius) {
        ball.x = FIELD_BOUNDARY_X - ballRadius;
        hitLeftRight = true;
    } else if (ball.x < -FIELD_BOUNDARY_X + ballRadius) {
        ball.x = -FIELD_BOUNDARY_X + ballRadius;
        hitLeftRight = true;
    }
    
    if (ball.y > FIELD_BOUNDARY_Y - ballRadius) {
        ball.y = FIELD_BOUNDARY_Y - ballRadius;
        hitTopBottom = true;
    } else if (ball.y < -FIELD_BOUNDARY_Y + ballRadius) {
        ball.y = -FIELD_BOUNDARY_Y + ballRadius;
        hitTopBottom = true;
    }
    
    // Bounce off walls
    if (hitTopBottom) {
        ball.dy *= -1.0f;
    }
    if (hitLeftRight) {
        // Only bounce if not in goal area
        if (std::abs(ball.y) > GOAL_HALF_WIDTH) {
            ball.dx *= -1.0f;
        } else {
            // Check for goal
            if (ball.x > 0.0f) {
                score.left++;
                resetGame(ball, team1, team2, gameState, 1);
                return -1;
            } else {
                score.right++;
                resetGame(ball, team1, team2, gameState, -1);
                return 1;
            }
        }
    }

    return 0;
}

// Updates one team's control flow (player input or AI), kicking, and possession.
void updateTeam(
    std::vector<Player>& team,
    std::vector<Player>& opponents,
    Ball& ball,
    bool isUserTeam,
    float deltaTime,
    const InputState& inputState,
    const GameState& gameState,
    const std::function<void(bool)>& onKick
) {
    using namespace Constants;

    bool teamPossessing = (ball.owner && ball.owner->side == team[0].side);

    int userPlayerIdx = -1;
    if (isUserTeam) {
        float minDist = 999.0f;
        for (int i = 0; i < static_cast<int>(team.size()); ++i) {
            if (team[i].role == PlayerRole::GOALKEEPER && ball.owner != &team[i]) {
                continue;
            }
            float d = std::sqrt(std::pow(team[i].x - ball.x, 2) + std::pow(team[i].y - ball.y, 2));
            if (d < minDist) {
                minDist = d;
                userPlayerIdx = i;
            }
        }
    }

    std::vector<int> chasers;
    if (!teamPossessing) {
        struct DistancePair {
            int index;
            float dist;
        };

        std::vector<DistancePair> distances;
        for (int i = 0; i < static_cast<int>(team.size()); ++i) {
            if (team[i].role == PlayerRole::GOALKEEPER) {
                continue;
            }
            float d = std::sqrt(std::pow(team[i].x - ball.x, 2) + std::pow(team[i].y - ball.y, 2));
            distances.push_back({i, d});
        }

        std::sort(
            distances.begin(),
            distances.end(),
            [](const DistancePair& a, const DistancePair& b) { return a.dist < b.dist; }
        );

        for (int j = 0; j < 2 && j < static_cast<int>(distances.size()); ++j) {
            chasers.push_back(distances[j].index);
        }
    }

    for (int i = 0; i < static_cast<int>(team.size()); ++i) {
        team[i].isMoving = false;
        if (gameState.kickoffTimer <= 0.0f && i == userPlayerIdx) {
            float speedMult = (team[i].stunTimer > 0.0f) ? 0.3f : 1.0f;
            if (team[i].kickPower > 0.0f) {
                speedMult *= 0.8f;
            }

            if (inputState.axisX != 0.0f || inputState.axisY != 0.0f) {
                team[i].x += inputState.axisX * team[i].speed * speedMult * deltaTime;
                team[i].y += inputState.axisY * team[i].speed * speedMult * deltaTime;
                
                // Keep player within boundaries (field or penalty area for goalkeeper)
                float playerHalfWidth = (team[i].role == PlayerRole::GOALKEEPER) ? 0.026f : 0.02f;
                if (team[i].role == PlayerRole::GOALKEEPER) {
                    float areaLimitX = FIELD_BOUNDARY_X - PENALTY_AREA_WIDTH;
                    if (team[i].side == -1) {
                        team[i].x = std::max(-FIELD_BOUNDARY_X + playerHalfWidth, std::min(-areaLimitX + playerHalfWidth, team[i].x));
                    } else {
                        team[i].x = std::max(areaLimitX - playerHalfWidth, std::min(FIELD_BOUNDARY_X - playerHalfWidth, team[i].x));
                    }
                    team[i].y = std::max(-PENALTY_AREA_HEIGHT + playerHalfWidth, std::min(PENALTY_AREA_HEIGHT - playerHalfWidth, team[i].y));
                } else {
                    team[i].x = std::max(-FIELD_BOUNDARY_X + playerHalfWidth, std::min(FIELD_BOUNDARY_X - playerHalfWidth, team[i].x));
                    team[i].y = std::max(-FIELD_BOUNDARY_Y + playerHalfWidth, std::min(FIELD_BOUNDARY_Y - playerHalfWidth, team[i].y));
                }
                
                if (inputState.axisX != 0.0f) team[i].facingX = inputState.axisX;
                if (inputState.axisY != 0.0f) team[i].facingY = inputState.axisY;
                team[i].isMoving = true;
                team[i].animTimer += deltaTime * 10.0f;
            }

            if (team[i].stunTimer > 0.0f) {
                team[i].stunTimer -= deltaTime;
            }

            if (ball.owner == &team[i]) {
                // Update Hissatsu charging effect
                ball.chargingPower = team[i].kickPower;
                
                if (inputState.spacePressed) {
                    team[i].kickPower += deltaTime * 2.0f;
                    if (team[i].kickPower > 1.0f) {
                        team[i].kickPower = 1.0f;
                    }
                } else if (inputState.spaceWasPressed) {
                    float dirX = inputState.mouseX - team[i].x;
                    float dirY = inputState.mouseY - team[i].y;
                    float mag = std::sqrt(dirX * dirX + dirY * dirY);
                    if (mag <= 0.001f) {
                        dirX = team[i].facingX;
                        dirY = team[i].facingY;
                        mag = std::sqrt(dirX * dirX + dirY * dirY);
                    }
                    if (mag <= 0.001f) {
                        dirX = static_cast<float>(team[i].side);
                        dirY = 0.0f;
                        mag = 1.0f;
                    }
                    float finalPower = (0.012f + (team[i].kickPower * 0.023f)) * 0.5f;
                    ball.dx = (dirX / mag) * finalPower;
                    ball.dy = (dirY / mag) * finalPower;

                    float targetGoalX = (team[i].side == -1) ? Constants::FIELD_BOUNDARY_X : -Constants::FIELD_BOUNDARY_X;
                    float distToGoal = std::sqrt(std::pow(team[i].x - targetGoalX, 2) + std::pow(team[i].y, 2));
                    if (team[i].kickPower > 0.5f && distToGoal < 0.6f) {
                        ball.isSuperShot = true;
                    } else {
                        ball.isSuperShot = false;
                    }

                    // Apply spin effect based on kick power (Magnus effect)
                    // Higher kick power = more spin = more curve
                    float spinStrength = team[i].kickPower * 2.0f;
                    ball.spinZ = spinStrength * 0.5f;  // Primary spin axis
                    ball.spinX = (std::rand() % 100 - 50) / 100.0f * spinStrength * 0.3f;
                    ball.spinY = (std::rand() % 100 - 50) / 100.0f * spinStrength * 0.3f;
                    ball.owner = nullptr;
                    ball.x += ball.dx * 2.0f;
                    ball.y += ball.dy * 2.0f;
                    ball.chargingPower = 0.0f;  // Reset Hissatsu charge after kick
                    team[i].kickPower = 0.0f;
                    team[i].stunTimer = 0.3f;
                    // Pass true if it's a special shot (super shot), false otherwise
                    onKick(ball.isSuperShot);
                }
            } else {
                team[i].kickPower = 0.0f;
                if (ball.owner != &team[i]) {
                    ball.chargingPower = 0.0f;  // Reset if not the ball owner
                }
            }
        } else if (gameState.kickoffTimer <= 0.0f) {
            team[i].is_targeting_ball = std::find(chasers.begin(), chasers.end(), i) != chasers.end();
            team[i].update(ball.x, ball.y, teamPossessing, ball.owner, team, opponents, deltaTime);

            if (ball.owner == &team[i]) {
                float targetGoalX = (team[i].side == -1) ? FIELD_BOUNDARY_X : -FIELD_BOUNDARY_X;

                Player* bestPassTarget = nullptr;
                float bestTargetScore = -1.0f;

                for (auto& mate : team) {
                    if (&mate == &team[i] || mate.role == PlayerRole::GOALKEEPER) {
                        continue;
                    }

                    // Calculate score based on proximity and player role
                    float mateDist = std::sqrt(std::pow(mate.x - team[i].x, 2) + std::pow(mate.y - team[i].y, 2));
                    
                    // Role bonus - strongly prioritize attackers
                    float roleBonus = 0.0f;
                    if (mate.role == PlayerRole::ATTACKER) roleBonus = 5.0f;
                    else if (mate.role == PlayerRole::MIDFIELDER) roleBonus = 2.0f;
                    else roleBonus = -1.0f;  // Penalize passes to defenders
                    
                    // Only allow passes FORWARD (closer to opponent's goal)
                    float mateDistToGoal = std::sqrt(std::pow(targetGoalX - mate.x, 2) + std::pow(0.0f - mate.y, 2));
                    float playerDistToGoal = std::sqrt(std::pow(targetGoalX - team[i].x, 2) + std::pow(0.0f - team[i].y, 2));
                    
                    // Only accept passes to players closer to goal (forward passes only)
                    if (mateDistToGoal >= playerDistToGoal) {
                        continue;  // Skip - pass would go backwards or sideways
                    }
                    
                    float score = (1.0f / (1.0f + mateDist)) + roleBonus;

                    bool isMateOpen = true;
                    for (const auto& opp : opponents) {
                        float oppToMateDist = std::sqrt(std::pow(opp.x - mate.x, 2) + std::pow(opp.y - mate.y, 2));
                        if (oppToMateDist < 0.2f) {
                            isMateOpen = false;
                            break;
                        }
                    }

                    if (isMateOpen && score > bestTargetScore) {
                        bestTargetScore = score;
                        bestPassTarget = &mate;
                    }
                }

                float distToGoal = std::sqrt(std::pow(targetGoalX - team[i].x, 2) + std::pow(0.0f - team[i].y, 2));
                bool canShoot = distToGoal < 0.4f;

                float randomUnit = static_cast<float>(std::rand()) / static_cast<float>(RAND_MAX);
                if (bestPassTarget && randomUnit < 1.8f * deltaTime) {
                    float passDirX = bestPassTarget->x - team[i].x;
                    float passDirY = bestPassTarget->y - team[i].y;
                    float passMag = std::sqrt(passDirX * passDirX + passDirY * passDirY);
                    if (passMag > 0.001f) {
                        float passPower = 0.012f;
                        ball.dx = (passDirX / passMag) * passPower;
                        ball.dy = (passDirY / passMag) * passPower;
                        ball.isSuperShot = false;
                        ball.owner = nullptr;
                        team[i].stunTimer = 0.8f;
                        onKick(false);  // Normal pass
                    }
                } else if (canShoot && randomUnit < 3.0f * deltaTime && distToGoal > 0.001f) {
                    float finalPower = 0.015f + (std::rand() % 10) / 1000.0f;
                    ball.dx = (targetGoalX - team[i].x) / distToGoal * finalPower;
                    ball.dy = (0.0f - team[i].y) / distToGoal * finalPower;
                    ball.isSuperShot = true;
                    ball.owner = nullptr;
                    ball.x += ball.dx * 2.0f;
                    ball.y += ball.dy * 2.0f;
                    team[i].stunTimer = 1.0f;
                    onKick(true);  // Close shot - special effect
                } else {
                    float dribbleDirX = targetGoalX - team[i].x;
                    float dribbleDirY = (0.0f - team[i].y) * 0.3f;
                    float dribbleMag = std::sqrt(dribbleDirX * dribbleDirX + dribbleDirY * dribbleDirY);
                    if (dribbleMag > 0.001f) {
                        float dribbleSpeed = team[i].speed * 0.8f * deltaTime;
                        team[i].x += (dribbleDirX / dribbleMag) * dribbleSpeed;
                        team[i].y += (dribbleDirY / dribbleMag) * dribbleSpeed;
                        
                        // Keep player within field boundaries
                        float playerRadius = 0.03f;
                        team[i].x = std::max(-FIELD_BOUNDARY_X + playerRadius, std::min(FIELD_BOUNDARY_X - playerRadius, team[i].x));
                        team[i].y = std::max(-FIELD_BOUNDARY_Y + playerRadius, std::min(FIELD_BOUNDARY_Y - playerRadius, team[i].y));
                        
                        team[i].facingX = dribbleDirX / dribbleMag;
                        team[i].facingY = dribbleDirY / dribbleMag;
                        team[i].isMoving = true;
                        team[i].animTimer += deltaTime * 10.0f;
                    }
                }
            }
        }

        float distToBall = std::sqrt(std::pow(team[i].x - ball.x, 2) + std::pow(team[i].y - ball.y, 2));
        if (distToBall < 0.04f) {
            if (!ball.owner && team[i].stunTimer <= 0.0f) {
                ball.owner = &team[i];
                ball.isSuperShot = false;
                ball.chargingPower = 0.0f;
            } else if (ball.owner && ball.owner->side != team[i].side && team[i].stunTimer <= 0.0f) {
                if (ball.owner->role != PlayerRole::GOALKEEPER) {
                    ball.owner->stunTimer = 0.5f;
                    ball.owner->kickPower = 0.0f;
                    ball.owner = &team[i];
                    ball.isSuperShot = false;
                    ball.chargingPower = 0.0f;
                }
            }
        }
    }
}
