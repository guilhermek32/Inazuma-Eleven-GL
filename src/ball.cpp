#include "ball.hpp"
#include "player.hpp"
#include "utils.hpp"
#include <glad/glad.h>
#include <cmath>

// Draws a textured quad centered at (x, y) with 2D rotation.
void renderTexturedQuadWithRotation(unsigned int textureId, float x, float y, float size, float rotationDegrees) {
    glPushMatrix();
    glTranslatef(x, y, 0.0f);
    glRotatef(rotationDegrees, 0.0f, 0.0f, 1.0f);
    glTranslatef(-size * 0.5f, -size * 0.5f, 0.0f);
    
    if (textureId != 0) {
        glBindTexture(GL_TEXTURE_2D, textureId);
        glEnable(GL_TEXTURE_2D);
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    }
    
    glColor4f(1.0f, 1.0f, 1.0f, 1.0f);
    glBegin(GL_QUADS);
    glTexCoord2f(0.0f, 0.0f);
    glVertex2f(0.0f, 0.0f);
    glTexCoord2f(1.0f, 0.0f);
    glVertex2f(size, 0.0f);
    glTexCoord2f(1.0f, 1.0f);
    glVertex2f(size, size);
    glTexCoord2f(0.0f, 1.0f);
    glVertex2f(0.0f, size);
    glEnd();
    
    if (textureId != 0) {
        glDisable(GL_BLEND);
    } else {
        glDisable(GL_TEXTURE_2D);
    }
    
    glPopMatrix();
}

// Loads normal and special ball textures from candidate asset folders.
void Ball::loadTextures() {
    std::vector<std::string> baseDirs = candidateBaseDirs();
    
    // Load normal ball animation frames - try all numbers from 1-5
    normalTextures.clear();
    for (int frame = 1; frame <= 5; frame++) {
        for (const auto& baseDir : baseDirs) {
            std::string path = baseDir + "ball/ball" + std::to_string(frame) + ".png";
            unsigned int tex = loadTextureFromPng(path.c_str());
            if (tex != 0) {
                normalTextures.push_back(tex);
                break;  // Found this frame, move to next
            }
        }
    }
    
    // If we found at least 1 frame, good! If not, use fallback
    if (normalTextures.empty()) {
        // Just use a dummy texture ID (we'll create a simple fallback in render)
        for (int i = 0; i < 4; i++) {
            normalTextures.push_back(0);
        }
    }
    
    // Load super shot ball texture
    superTexture = 0;
    for (const auto& baseDir : baseDirs) {
        std::string path = baseDir + "ball/ball_super1.png";
        superTexture = loadTextureFromPng(path.c_str());
        if (superTexture != 0) {
            break;
        }
    }
}

// Updates ball animation, spin/curve physics, and motion trail buffers.
void Ball::update(float deltaTime) {
    // Update motion blur trail
    if (trailX.size() >= TRAIL_LENGTH) {
        trailX.erase(trailX.begin());
        trailY.erase(trailY.begin());
    }
    trailX.push_back(x);
    trailY.push_back(y);
    
    float speed = std::sqrt(dx * dx + dy * dy);

    // Check if owner is moving
    bool ownerMoving = (owner != nullptr && owner->isMoving);
    
    // Update animation frame while carried or rolling.
    if ((ownerMoving || speed > 0.0001f) && !isSuperShot && !normalTextures.empty()) {
        animationTimer += deltaTime;
        // Change frame every 0.15 seconds (faster animation)
        if (animationTimer >= 0.15f) {
            currentFrame = (currentFrame + 1) % normalTextures.size();
            animationTimer = 0.0f;
        }
    } else if (isSuperShot) {
        // Super shot ball doesn't animate, but rotates faster
        animationTimer = 0.0f;
        currentFrame = 0;
    } else if (!ownerMoving && speed <= 0.0001f) {
        // Reset animation timer if owner stops moving
        animationTimer = 0.0f;
    }
    
    // Calculate rotation based on velocity.
    // Rotation speed is proportional to ball speed
    if (speed > 0.0001f) {
        // Rotate based on velocity direction and magnitude
        // Speed multiplier: increases significantly when ball is kicked
        float rotationSpeedMultiplier = 5400.0f;  // Base rotation speed (was 3600.0f)
        
        // If ball is moving fast (kicked), rotate MUCH faster
        if (speed > 0.3f) {
            rotationSpeedMultiplier = 9000.0f;  // Much faster when kicked
        }
        
        rotation += speed * rotationSpeedMultiplier * deltaTime * 60.0f;
        if (rotation > 360.0f) {
            rotation = std::fmod(rotation, 360.0f);
        }
        
        // Apply Magnus effect (curve) based on spin
        // Magnus force creates deviation perpendicular to velocity
        float spinMagnitude = std::sqrt(spinX * spinX + spinY * spinY + spinZ * spinZ);
        if (spinMagnitude > 0.01f) {
            // Cross product: velocity × spin = Magnus force direction
            float magnusForce = spinMagnitude * magnusForceScale * 0.05f;
            
            // Apply perpendicular force to create curve
            float perpX = -dy * magnusForce;
            float perpY = dx * magnusForce;
            
            dx += perpX * deltaTime;
            dy += perpY * deltaTime;
            
            // Spin decays over time (friction on spin)
            float spinDecay = std::pow(0.98f, deltaTime * 60.0f);
            spinX *= spinDecay;
            spinY *= spinDecay;
            spinZ *= spinDecay;
        }
    }
}

// Renders the ball sprite, or a debug fallback if texture loading failed.
void Ball::render() {
    // Select texture based on state
    unsigned int texToUse = 0;
    
    if (isSuperShot && superTexture != 0) {
        texToUse = superTexture;
    } else if (!normalTextures.empty() && currentFrame < normalTextures.size() && normalTextures[currentFrame] != 0) {
        texToUse = normalTextures[currentFrame];
    }
    
    if (texToUse != 0) {
        // Render with rotation
        float ballSize = 0.02f;  // Size of the ball sprite
        renderTexturedQuadWithRotation(texToUse, x, y, ballSize, rotation);
    } else {
        // Fallback: render yellow square if no texture
        float ballSize = 0.04f;  // Larger size for visibility
        glDisable(GL_TEXTURE_2D);
        glColor3f(1.0f, 1.0f, 0.0f);  // Yellow color for visibility
        glPushMatrix();
        glTranslatef(x - ballSize * 0.5f, y - ballSize * 0.5f, 0.0f);
        glBegin(GL_QUADS);
        glVertex2f(0.0f, 0.0f);
        glVertex2f(ballSize, 0.0f);
        glVertex2f(ballSize, ballSize);
        glVertex2f(0.0f, ballSize);
        glEnd();
        glPopMatrix();
        glEnable(GL_TEXTURE_2D);
    }
}

// Renders a fading point trail to simulate motion blur at high speed.
void Ball::renderMotionBlur() {
    // Render motion blur trail only if ball is moving fast
    float speed = std::sqrt(dx * dx + dy * dy);
    if (speed < 0.001f || trailX.empty()) {
        return;
    }
    
    // Render trail points with fading alpha
    glDisable(GL_TEXTURE_2D);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    
    for (std::size_t i = 0; i < trailX.size(); i++) {
        float alpha = static_cast<float>(i) / trailX.size() * 0.5f;
        glColor4f(1.0f, 1.0f, 1.0f, alpha);
        glPointSize(6.0f - (static_cast<float>(i) / trailX.size()) * 4.0f);
        glBegin(GL_POINTS);
        glVertex2f(trailX[i], trailY[i]);
        glEnd();
    }
    
    glDisable(GL_BLEND);
    glEnable(GL_TEXTURE_2D);
}

// Renders charged-shot visual effects around the ball.
void Ball::renderHissatsuEffect(float kickPower) {
    if (kickPower <= 0.0f) return;
    
    glDisable(GL_TEXTURE_2D);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    
    // Rotation angle based on time
    static float time = 0.0f;
    time += 0.05f;
    
    // Size based on power
    float orbitRadius = 0.025f + (kickPower * 0.015f);  // Orbit distance
    float alpha = 0.4f + (kickPower * 0.5f);
    
    // Color changes based on power level
    float r, g, b;
    if (kickPower > 0.8f) {
        // Super power - Golden/White
        r = 1.0f;
        g = 0.9f;
        b = 0.3f;
    } else if (kickPower > 0.5f) {
        // Strong power - Orange/Yellow
        r = 1.0f;
        g = 0.6f;
        b = 0.0f;
    } else {
        // Charging - Cyan/Blue
        r = 0.0f;
        g = 0.7f;
        b = 1.0f;
    }
    
    // Draw 3 rotating rings around the ball
    int numRings = 3;
    for (int ring = 0; ring < numRings; ring++) {
        float ringRadius = orbitRadius * (0.6f + ring * 0.3f);
        float ringSpeed = 1.5f + ring * 0.8f;  // Different speeds for each ring
        float ringAngle = time * ringSpeed + ring * 2.0f;
        
        // Number of particles per ring
        int numOrb = 4 + ring * 2;
        
        for (int i = 0; i < numOrb; i++) {
            float angle = ringAngle + (static_cast<float>(i) / numOrb) * 3.14159265f * 2.0f;
            
            // Calculate orb position
            float px = x + std::cos(angle) * ringRadius;
            float py = y + std::sin(angle) * ringRadius;
            
            // Size decreases for outer rings
            float orbSize = 4.0f - ring * 0.8f + kickPower * 2.0f;
            
            // Alpha fades for outer rings
            float orbAlpha = alpha * (1.0f - ring * 0.2f);
            
            glColor4f(r, g, b, orbAlpha);
            glPointSize(orbSize);
            glBegin(GL_POINTS);
            glVertex2f(px, py);
            glEnd();
            
            // Draw trail line from previous position for each orb
            if (ring == 0) {  // Only on inner ring for performance
                float trailAngle = angle - 0.3f;
                float trailX = x + std::cos(trailAngle) * ringRadius;
                float trailY = y + std::sin(trailAngle) * ringRadius;
                
                glColor4f(r, g, b, orbAlpha * 0.5f);
                glLineWidth(2.0f);
                glBegin(GL_LINES);
                glVertex2f(trailX, trailY);
                glVertex2f(px, py);
                glEnd();
            }
        }
    }
    
    // Draw speed lines radiating outward when power is high
    if (kickPower > 0.5f) {
        int numLines = 6;
        float lineLength = 0.02f + kickPower * 0.02f;
        
        for (int i = 0; i < numLines; i++) {
            float baseAngle = time * 2.0f + (static_cast<float>(i) / numLines) * 3.14159265f * 2.0f;
            float lineAlpha = (kickPower - 0.5f) * 2.0f * 0.6f;
            
            float startX = x + std::cos(baseAngle) * orbitRadius;
            float startY = y + std::sin(baseAngle) * orbitRadius;
            float endX = x + std::cos(baseAngle) * (orbitRadius + lineLength);
            float endY = y + std::sin(baseAngle) * (orbitRadius + lineLength);
            
            glColor4f(r, g, b, lineAlpha);
            glLineWidth(1.5f);
            glBegin(GL_LINES);
            glVertex2f(startX, startY);
            glVertex2f(endX, endY);
            glEnd();
        }
    }
    
    glDisable(GL_BLEND);
    glEnable(GL_TEXTURE_2D);
}
