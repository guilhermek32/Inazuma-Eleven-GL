#define GLFW_INCLUDE_NONE
#include <glad/glad.h>
#include <GLFW/glfw3.h>
#include <cstdlib>

#include "ball.hpp"
#include "audio.hpp"
#include "field.hpp"
#include "game.hpp"
#include "game_logic.hpp"
#include "input.hpp"
#include "stadium.hpp"
#include "player.hpp"
#include "constants.hpp"
#include "utils.hpp"
#include "particle.hpp"

#include <vector>
#include <string>

// Bootstraps the whole match loop: setup, update, render, and teardown.
int runGame()
{
    if (!glfwInit()) return -1;
    GLFWwindow* window = glfwCreateWindow(1600, 900, "Inazuma Eleven GL", NULL, NULL);
    if (!window) { glfwTerminate(); return -1; }
    glfwMakeContextCurrent(window);
    if (!gladLoadGLLoader((GLADloadproc)glfwGetProcAddress)) {
        glfwDestroyWindow(window);
        glfwTerminate();
        return -1;
    }
    glViewport(0, 0, 1600, 900);
    glfwSwapInterval(1);

    using namespace Constants;
    Field field; Stadium stadium;
    AudioPlayer audioPlayer;
    GameState gameState{2.0f};
    Ball ball{0.0f, 0.0f, 0.005f, 0.002f, 0.98f, nullptr};
    Score score{0, 0};
    InputState inputState{0.0f, 0.0f, false, false, 0.0f, 0.0f};
    ParticleSystem particles;  // Particle system for effects
    const float initialPlayerSpeed = 0.2f;

    // Load Sprites
    unsigned int blueFace = 0, blueBack = 0, blueLeft = 0, blueRight = 0;
    unsigned int redFace = 0, redBack = 0, redLeft = 0, redRight = 0;
    unsigned int texGKBlue = 0;
    unsigned int texGKRed = 0;
    std::vector<unsigned int> blueRunFramesRight;
    std::vector<unsigned int> blueRunFramesLeft;
    std::vector<unsigned int> redRunFramesRight;
    std::vector<unsigned int> redRunFramesLeft;
    
    std::vector<std::string> baseDirs = candidateBaseDirs();
    bool audioStarted = false;
    std::vector<std::string> kickSoundPaths;
    std::vector<std::string> refereeStartSoundPaths;
    
    // Try to initialize audio from baseDirs first
    for (const auto& baseDir : baseDirs) {
        kickSoundPaths.push_back(baseDir + "sound/kick.mp3");
        refereeStartSoundPaths.push_back(baseDir + "sound/referee-start.mp3");
        if (audioPlayer.initLoopingTrack(baseDir + "sound/background-sound.mp3")) {
            audioStarted = true;
            break;
        }
    }

    // Fallback to assets folder
    if (!audioStarted) {
        if (audioPlayer.initLoopingTrack("assets/sound/background-sound.mp3")) {
            audioStarted = true;
        }
    }
    
    // Always add fallback sound paths
    kickSoundPaths.push_back("assets/sound/kick.mp3");
    refereeStartSoundPaths.push_back("assets/sound/referee-start.mp3");

    auto onKick = [&audioPlayer, &kickSoundPaths, &particles, &ball](bool isSpecialShot = false) {
        // Play kick sound
        for (const std::string& kickPath : kickSoundPaths) {
            if (audioPlayer.playOneShot(kickPath)) {
                break;
            }
        }
        // Emit particles based on shot type
        if (isSpecialShot) {
            // Random choice between fire and ice
            bool isFire = (std::rand() % 2) == 0;
            if (isFire) {
                // Fire trail: red/orange/yellow particles
                particles.emit(ball.x, ball.y, ball.dx * 2.0f, ball.dy * 2.0f, 25, 0.8f, 5.0f, 1.0f, 0.5f, 0.0f);     // Red-orange
                particles.emit(ball.x, ball.y, ball.dx * 2.0f, ball.dy * 2.0f, 15, 0.6f, 4.0f, 1.0f, 0.8f, 0.0f);     // Yellow
            } else {
                // Ice trail: cyan/light blue/white particles
                particles.emit(ball.x, ball.y, ball.dx * 2.0f, ball.dy * 2.0f, 25, 0.8f, 5.0f, 0.3f, 0.8f, 1.0f);     // Cyan
                particles.emit(ball.x, ball.y, ball.dx * 2.0f, ball.dy * 2.0f, 15, 0.6f, 4.0f, 0.7f, 0.9f, 1.0f);     // Light blue
            }
        } else {
            // Normal dust particles at ball position
            particles.emit(ball.x, ball.y, ball.dx * 2.0f, ball.dy * 2.0f, 15, 0.5f, 4.0f, 0.8f, 0.7f, 0.5f);
        }
    };

    for (const auto& baseDir : baseDirs) {
        if (blueFace == 0) blueFace = loadTextureFromPng((baseDir + "players_blue/face_blue.png").c_str());
        if (blueBack == 0) blueBack = loadTextureFromPng((baseDir + "players_blue/back_blue.png").c_str());
        if (blueLeft == 0) blueLeft = loadTextureFromPng((baseDir + "players_blue/left_blue.png").c_str());
        if (blueRight == 0) blueRight = loadTextureFromPng((baseDir + "players_blue/right_blue.png").c_str());

        if (redFace == 0) redFace = loadTextureFromPng((baseDir + "players_red/face_Red.png").c_str());
        if (redBack == 0) redBack = loadTextureFromPng((baseDir + "players_red/back_red.png").c_str());
        if (redLeft == 0) redLeft = loadTextureFromPng((baseDir + "players_red/left_red.png").c_str());
        if (redRight == 0) redRight = loadTextureFromPng((baseDir + "players_red/right_red.png").c_str());

        if (texGKBlue == 0) texGKBlue = loadTextureFromPng((baseDir + "players_blue/gk_blue_left.png").c_str());
        if (texGKRed == 0) texGKRed = loadTextureFromPng((baseDir + "players_red/gk_red_right_1.png").c_str());
        
        if (blueRunFramesRight.empty()) {
            unsigned int f1 = loadTextureFromPng((baseDir + "players_blue/running/run_blue1.png").c_str());
            unsigned int f2 = loadTextureFromPng((baseDir + "players_blue/running/run_blue2.png").c_str());
            unsigned int f3 = loadTextureFromPng((baseDir + "players_blue/running/run_blue3.png").c_str());
            unsigned int f4 = loadTextureFromPng((baseDir + "players_blue/running/run_blue4.png").c_str());
            if (f1 && f2 && f3 && f4) {
                blueRunFramesRight = {f1, f2, f3, f4};
            }
        }
        if (blueRunFramesLeft.empty()) {
            unsigned int f1 = loadTextureFromPng((baseDir + "players_blue/running/run_blue1_left.png").c_str());
            unsigned int f2 = loadTextureFromPng((baseDir + "players_blue/running/run_blue2_left.png").c_str());
            unsigned int f3 = loadTextureFromPng((baseDir + "players_blue/running/run_blue3_left.png").c_str());
            unsigned int f4 = loadTextureFromPng((baseDir + "players_blue/running/run_blue_left4.png").c_str());
            if (f1 && f2 && f3 && f4) {
                blueRunFramesLeft = {f1, f2, f3, f4};
            }
        }
        if (redRunFramesRight.empty()) {
            unsigned int f1 = loadTextureFromPng((baseDir + "players_red/running/run_red_1.png").c_str());
            unsigned int f2 = loadTextureFromPng((baseDir + "players_red/running/run_red2.png").c_str());
            unsigned int f3 = loadTextureFromPng((baseDir + "players_red/running/run_red3.png").c_str());
            unsigned int f4 = loadTextureFromPng((baseDir + "players_red/running/run_red4.png").c_str());
            if (f1 && f2 && f3 && f4) {
                redRunFramesRight = {f1, f2, f3, f4};
            }
        }
        if (redRunFramesLeft.empty()) {
            unsigned int f2 = loadTextureFromPng((baseDir + "players_red/running/run_red_left2.png").c_str());
            unsigned int f3 = loadTextureFromPng((baseDir + "players_red/running/run_red_left3.png").c_str());
            unsigned int f4 = loadTextureFromPng((baseDir + "players_red/running/run_red_left4.png").c_str());
            if (f2 && f3 && f4) {
                redRunFramesLeft = {f2, f3, f4};
            }
        }
    }

    std::vector<Player> team1;
    std::vector<Player> team2;

    // Team 1 (Red)
    team1.push_back(Player(-FIELD_BOUNDARY_X,  0.00f, initialPlayerSpeed, -1, PlayerRole::GOALKEEPER, texGKRed, texGKRed, texGKRed, texGKRed));
    team1.push_back(Player(-0.65f,  0.25f, initialPlayerSpeed, -1, PlayerRole::DEFENDER, redFace, redBack, redLeft, redRight));
    team1.push_back(Player(-0.65f, -0.25f, initialPlayerSpeed, -1, PlayerRole::DEFENDER, redFace, redBack, redLeft, redRight));
    team1.push_back(Player(-0.60f,  0.50f, initialPlayerSpeed, -1, PlayerRole::DEFENDER, redFace, redBack, redLeft, redRight));
    team1.push_back(Player(-0.60f, -0.50f, initialPlayerSpeed, -1, PlayerRole::DEFENDER, redFace, redBack, redLeft, redRight));
    team1.push_back(Player(-0.35f,  0.00f, initialPlayerSpeed, -1, PlayerRole::MIDFIELDER, redFace, redBack, redLeft, redRight));
    team1.push_back(Player(-0.35f,  0.30f, initialPlayerSpeed, -1, PlayerRole::MIDFIELDER, redFace, redBack, redLeft, redRight));
    team1.push_back(Player(-0.35f, -0.30f, initialPlayerSpeed, -1, PlayerRole::MIDFIELDER, redFace, redBack, redLeft, redRight));
    team1.push_back(Player(-0.10f,  0.00f, initialPlayerSpeed, -1, PlayerRole::ATTACKER, redFace, redBack, redLeft, redRight));
    team1.push_back(Player(-0.10f,  0.40f, initialPlayerSpeed, -1, PlayerRole::ATTACKER, redFace, redBack, redLeft, redRight));
    team1.push_back(Player(-0.10f, -0.40f, initialPlayerSpeed, -1, PlayerRole::ATTACKER, redFace, redBack, redLeft, redRight));

    for (auto& p : team1) {
        if (p.role != PlayerRole::GOALKEEPER) {
            p.runFramesRight = redRunFramesRight;
            p.runFramesLeft = redRunFramesLeft;
            // Debug: ensure frames are assigned
            if (p.runFramesRight.empty()) {
                p.runFramesRight = {redFace, redFace, redFace, redFace};
            }
            if (p.runFramesLeft.empty()) {
                p.runFramesLeft = {redFace, redFace, redFace, redFace};
            }
        }
    }

    // Team 2 (Blue)
    team2.push_back(Player( FIELD_BOUNDARY_X,  0.00f, initialPlayerSpeed,  1, PlayerRole::GOALKEEPER, texGKBlue, texGKBlue, texGKBlue, texGKBlue));
    team2.push_back(Player( 0.65f,  0.25f, initialPlayerSpeed,  1, PlayerRole::DEFENDER, blueFace, blueBack, blueLeft, blueRight));
    team2.push_back(Player( 0.65f, -0.25f, initialPlayerSpeed,  1, PlayerRole::DEFENDER, blueFace, blueBack, blueLeft, blueRight));
    team2.push_back(Player( 0.60f,  0.50f, initialPlayerSpeed,  1, PlayerRole::DEFENDER, blueFace, blueBack, blueLeft, blueRight));
    team2.push_back(Player( 0.60f, -0.50f, initialPlayerSpeed,  1, PlayerRole::DEFENDER, blueFace, blueBack, blueLeft, blueRight));
    team2.push_back(Player( 0.35f,  0.00f, initialPlayerSpeed,  1, PlayerRole::MIDFIELDER, blueFace, blueBack, blueLeft, blueRight));
    team2.push_back(Player( 0.35f,  0.30f, initialPlayerSpeed,  1, PlayerRole::MIDFIELDER, blueFace, blueBack, blueLeft, blueRight));
    team2.push_back(Player( 0.35f, -0.30f, initialPlayerSpeed,  1, PlayerRole::MIDFIELDER, blueFace, blueBack, blueLeft, blueRight));
    team2.push_back(Player( 0.10f,  0.00f, initialPlayerSpeed,  1, PlayerRole::ATTACKER, blueFace, blueBack, blueLeft, blueRight));
    team2.push_back(Player( 0.10f,  0.40f, initialPlayerSpeed,  1, PlayerRole::ATTACKER, blueFace, blueBack, blueLeft, blueRight));
    team2.push_back(Player( 0.10f, -0.40f, initialPlayerSpeed,  1, PlayerRole::ATTACKER, blueFace, blueBack, blueLeft, blueRight));

    for (auto& p : team2) {
        if (p.role != PlayerRole::GOALKEEPER) {
            p.runFramesRight = blueRunFramesRight;
            p.runFramesLeft = blueRunFramesLeft;
            // Debug: ensure frames are assigned
            if (p.runFramesRight.empty()) {
                p.runFramesRight = {blueFace, blueFace, blueFace, blueFace};
            }
            if (p.runFramesLeft.empty()) {
                p.runFramesLeft = {blueFace, blueFace, blueFace, blueFace};
            }
        }
    }

    resetGame(ball, team1, team2, gameState, 1);
    
    // Load ball sprites
    ball.loadTextures();

    float lastFrameTime = glfwGetTime();

bool kickoffStarted = false;
        
        while (!glfwWindowShouldClose(window)) {
            float currentFrameTime = glfwGetTime();
            float deltaTime = currentFrameTime - lastFrameTime;
            lastFrameTime = currentFrameTime;
            stadium.update(deltaTime);

            // Play referee whistle when kickoff starts
            if (gameState.kickoffTimer > 0.0f) {
                if (!kickoffStarted) {
                    gameState.kickoffTimer -= deltaTime;
                    if (gameState.kickoffTimer <= 0.0f && audioPlayer.init()) {
                        kickoffStarted = true;
                        for (const std::string& refPath : refereeStartSoundPaths) {
                            if (audioPlayer.playOneShot(refPath, 0.3f)) {  // Lower volume for referee whistle
                                break;
                            }
                        }
                    }
                }
            }

        glClear(GL_COLOR_BUFFER_BIT);
        processInput(window, inputState, gameState.kickoffTimer <= 0.0f);
        int scorerSide = updateBall(ball, score, team1, team2, gameState, deltaTime);
        if (scorerSide != 0) {
            stadium.triggerCrowdCelebration(scorerSide);
            // Clear old particles and emit celebration
            particles.clear();
            float goalX = (scorerSide > 0) ? -0.93f : 0.93f;
            particles.emit(goalX, 0.0f, 0.0f, 0.5f, 40, 1.5f, 6.0f, 1.0f, 0.84f, 0.0f);
            // Reset kickoff flag so timer counts down
            kickoffStarted = false;
        }
        ball.update(deltaTime);
        particles.update(deltaTime);
        updateTeam(team1, team2, ball, true, deltaTime, inputState, gameState, onKick);
        updateTeam(team2, team1, ball, false, deltaTime, inputState, gameState, onKick);

        stadium.render(); stadium.renderScoreboard(score.left, score.right);
        field.render();

        ball.render();
        ball.renderHissatsuEffect(ball.chargingPower);
        ball.renderMotionBlur();
        particles.render();
        for(auto& p : team1) { p.render(); p.renderPowerBar(); }
        for(auto& p : team2) { p.render(); p.renderPowerBar(); }

        glfwSwapBuffers(window);
        glfwPollEvents();
    }
    auto deleteTexture = [](unsigned int& texture) {
        if (texture != 0) {
            glDeleteTextures(1, &texture);
            texture = 0;
        }
    };
    auto deleteTextureVector = [](std::vector<unsigned int>& textures) {
        for (unsigned int& texture : textures) {
            if (texture != 0) {
                glDeleteTextures(1, &texture);
                texture = 0;
            }
        }
        textures.clear();
    };
    deleteTexture(blueFace);
    deleteTexture(blueBack);
    deleteTexture(blueLeft);
    deleteTexture(blueRight);
    deleteTexture(redFace);
    deleteTexture(redBack);
    deleteTexture(redLeft);
    deleteTexture(redRight);
    deleteTexture(texGKBlue);
    deleteTexture(texGKRed);
    deleteTextureVector(blueRunFramesRight);
    deleteTextureVector(blueRunFramesLeft);
    deleteTextureVector(redRunFramesRight);
    deleteTextureVector(redRunFramesLeft);
    deleteTextureVector(ball.normalTextures);
    deleteTexture(ball.superTexture);
    stadium.shutdown();
    audioPlayer.shutdown();
    glfwDestroyWindow(window);
    glfwTerminate();
    return 0;
}
