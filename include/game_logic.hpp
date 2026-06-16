#ifndef GAME_LOGIC_HPP
#define GAME_LOGIC_HPP

#include "ball.hpp"
#include "input.hpp"
#include "player.hpp"

#include <functional>
#include <vector>

struct Score {
    int left;
    int right;
};

struct GameState {
    float kickoffTimer;
};

void resetGame(Ball& ball, std::vector<Player>& team1, std::vector<Player>& team2, GameState& gameState, int scoringTeamSide);

int updateBall(Ball& ball, Score& score, std::vector<Player>& team1, std::vector<Player>& team2, GameState& gameState, float deltaTime);

void updateTeam(
    std::vector<Player>& team,
    std::vector<Player>& opponents,
    Ball& ball,
    bool isUserTeam,
    float deltaTime,
    const InputState& inputState,
    const GameState& gameState,
    const std::function<void(bool)>& onKick
);

#endif
